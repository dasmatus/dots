//! The daemon's D-Bus interface.
//!
//! The session bus rather than a private socket, because everything the
//! daemon needs from a transport it already has there: `busctl --user` can
//! introspect and drive it by hand, name ownership tells systemd when the
//! service is genuinely up (`Type=dbus`), and a name dies with the process
//! that held it — so there is no stale socket file to reclaim on a crash.
//!
//! Every method body below is an inherent method taking plain arguments, with
//! the `#[zbus::interface]` block a thin wrapper over it. That split is what
//! lets the whole surface be tested without conjuring a session bus.
//!
//! Threading: the object server runs on zbus's own thread, so nothing here
//! may block for as long as the panel is open. [`Beamenu::show`] and
//! [`Beamenu::reload`] hand a [`Signal`] to the UI thread and return
//! immediately; `RunCommand` needs no launcher state at all and so runs
//! inline; the properties read atomics the UI thread publishes.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, RwLock};

use crate::dispatch;
use crate::item::Action;
use crate::providers::system;

/// The well-known name the daemon owns on the session bus.
pub const BUS_NAME: &str = "dev.dots.Beamenu";

/// The object the interface is exported at.
pub const OBJECT_PATH: &str = "/dev/dots/Beamenu";

/// What the bus thread asks the UI thread to do.
///
/// Deliberately only the two things that need the UI thread. Anything that
/// can be answered without it is answered on the bus thread instead, so a
/// method call never waits on a panel the user has not dismissed yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Show,
    Reload,
}

/// State the UI thread publishes and the bus thread reads.
#[derive(Debug)]
pub struct Shared {
    /// True while the panel is up. Read by `Show` to stay idempotent.
    pub visible: AtomicBool,
    pub apps: AtomicUsize,
    pub providers: AtomicUsize,
    /// The configured terminal emulator, republished on every refresh so a
    /// `RunCommand` arriving after a Home Manager switch uses the new one.
    pub terminal: RwLock<String>,
}

impl Shared {
    #[must_use]
    pub fn new() -> Self {
        Self {
            visible: AtomicBool::new(false),
            apps: AtomicUsize::new(0),
            providers: AtomicUsize::new(0),
            terminal: RwLock::new(String::new()),
        }
    }
}

impl Default for Shared {
    fn default() -> Self {
        Self::new()
    }
}

/// Run one system command by id.
///
/// Split out of the D-Bus method so it can be called with two strings.
///
/// # Errors
/// Returns a message naming the id when no such command exists, or the
/// dispatch failure otherwise.
pub fn run_command(id: &str, terminal: &str) -> Result<(), String> {
    let Some(command) = system::command_for(id) else {
        return Err(format!("unknown command '{id}'"));
    };
    // The command list is all shell one-liners; dispatch still wants a
    // terminal for its Launch arm, which is why one is threaded through.
    dispatch::dispatch(&Action::Shell(command.to_string()), terminal).map_err(|err| err.to_string())
}

/// The exported object.
pub struct Beamenu {
    tx: Sender<Signal>,
    shared: Arc<Shared>,
}

impl Beamenu {
    #[must_use]
    pub fn new(tx: Sender<Signal>, shared: Arc<Shared>) -> Self {
        Self { tx, shared }
    }

    /// Ask the UI thread to open the launcher. Returns whether the signal
    /// was delivered — or was deliberately not needed.
    ///
    /// A show while the panel is already up sends nothing and still reports
    /// success: that is a second keypress, and queueing it would reopen the
    /// launcher at some arbitrary moment after the user dismissed it.
    #[must_use]
    pub fn show(&self) -> bool {
        if self.shared.visible.load(Ordering::SeqCst) {
            return true;
        }
        self.tx.send(Signal::Show).is_ok()
    }

    /// Ask the UI thread to rebuild its cached configuration.
    #[must_use]
    pub fn reload(&self) -> bool {
        self.tx.send(Signal::Reload).is_ok()
    }

    #[must_use]
    pub fn visible(&self) -> bool {
        self.shared.visible.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn apps(&self) -> usize {
        self.shared.apps.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn providers(&self) -> usize {
        self.shared.providers.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn version(&self) -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    fn terminal(&self) -> String {
        self.shared
            .terminal
            .read()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }
}

/// `dev.dots.Beamenu1`.
#[zbus::interface(name = "dev.dots.Beamenu1")]
impl Beamenu {
    /// Open the launcher.
    #[zbus(name = "Show")]
    fn dbus_show(&self) -> zbus::fdo::Result<()> {
        if self.show() {
            Ok(())
        } else {
            Err(zbus::fdo::Error::Failed(
                "the launcher thread is gone".to_string(),
            ))
        }
    }

    /// Run one system command by id.
    #[zbus(name = "RunCommand")]
    fn dbus_run_command(&self, id: &str) -> zbus::fdo::Result<()> {
        run_command(id, &self.terminal()).map_err(zbus::fdo::Error::InvalidArgs)
    }

    /// Rebuild cached configuration before the next show.
    #[zbus(name = "Reload")]
    fn dbus_reload(&self) -> zbus::fdo::Result<()> {
        if self.reload() {
            Ok(())
        } else {
            Err(zbus::fdo::Error::Failed(
                "the launcher thread is gone".to_string(),
            ))
        }
    }

    #[zbus(property, name = "Visible")]
    fn dbus_visible(&self) -> bool {
        self.visible()
    }

    #[zbus(property, name = "Apps")]
    fn dbus_apps(&self) -> u32 {
        u32::try_from(self.apps()).unwrap_or(u32::MAX)
    }

    #[zbus(property, name = "Providers")]
    fn dbus_providers(&self) -> u32 {
        u32::try_from(self.providers()).unwrap_or(u32::MAX)
    }

    #[zbus(property, name = "Version")]
    fn dbus_version(&self) -> String {
        self.version().to_string()
    }
}

/// Call one method on a running daemon.
///
/// Returns `Err` for every reason a call might not land — no session bus, no
/// daemon owning the name, a method error — because the caller treats them
/// identically: do the work in-process instead. The distinction only matters
/// for the message, and a keybind has nowhere to print one.
///
/// # Errors
/// Fails when the bus, the name, or the call itself is unavailable.
pub fn call(method: &str, arg: Option<&str>) -> zbus::Result<()> {
    let connection = zbus::blocking::Connection::session()?;
    let proxy =
        zbus::blocking::Proxy::new(&connection, BUS_NAME, OBJECT_PATH, "dev.dots.Beamenu1")?;
    match arg {
        Some(value) => proxy.call::<_, _, ()>(method, &(value,)),
        None => proxy.call::<_, _, ()>(method, &()),
    }
}
