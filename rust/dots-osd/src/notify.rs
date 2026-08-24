//! Getting a [`Notification`] onto the screen, over the session bus.
//!
//! `org.freedesktop.Notifications` directly rather than a `notify-send` fork.
//! The volume keys repeat while held, so this runs many times a second at the
//! worst possible moment; a fork costs around twenty milliseconds and a bus
//! call costs a fraction of one. It also matches how the rest of this desktop
//! talks to itself: the launcher owns `dev.dots.Beamenu` on the same bus, so
//! there is one transport to reason about rather than two.
//!
//! There is no trait over this and no second implementation. Everything that
//! *decides* a notification returns one instead of sending it, which is what
//! makes [`crate::watch`] testable against plain structs; by the time a value
//! reaches here every decision has already been made and checked, and a fake
//! bus would only prove the fake works.

use std::collections::HashMap;
use std::time::Duration;

use zbus::zvariant::Value;

use crate::error::{Error, Result};
use crate::model::Notification;

/// The name notifications are attributed to, and what a rule in the user's
/// notification daemon would match on to restyle them.
pub const APP_NAME: &str = "dots-osd";

const BUS_NAME: &str = "org.freedesktop.Notifications";
const OBJECT_PATH: &str = "/org/freedesktop/Notifications";
const INTERFACE: &str = "org.freedesktop.Notifications";

/// How long to wait for the notification daemon to answer a call.
///
/// zbus applies no timeout unless asked, and `Bus::send` runs inside the
/// watcher's single sequential loop. A daemon that *crashes* is already handled
/// (the connection breaks and the call returns an error), but one that accepts
/// the call and never replies would park that loop forever, and every later
/// notification, the VPN drop and the disk at 94% included, would silently stop
/// arriving with nothing in the journal to say why. Five seconds is far longer
/// than a healthy daemon takes and far shorter than "never".
const METHOD_TIMEOUT: Duration = Duration::from_secs(5);

/// Escape text so a notification daemon renders it literally.
///
/// The freedesktop spec lets a summary and body carry markup, and this desktop
/// turns that on: `nix/home/dunst.nix` sets `markup = "full"` and a format of
/// `<b>%s</b>\n%b`, so both fields reach Pango's parser. Escaping is therefore
/// the sender's job, and this crate never means any of its text as markup.
///
/// It matters because several bodies interpolate text nobody here controls. An
/// SSID is chosen by whoever runs the access point. A process name comes from
/// `/proc/<pid>/comm`, which any local process picks for itself. Verified
/// against the running dunst: a body of `plain <b>BOLD</b> plain` arrives at
/// the renderer verbatim, so an access point named `<b>Bank</b>` would style
/// itself inside your notification, and one with an unclosed tag would hand
/// Pango markup it cannot parse.
///
/// The same check confirmed this does not double-escape. dunst repairs a bare
/// `&` on its own but leaves an already-valid `&amp;` alone, so text escaped
/// here renders as the literal characters it started as.
///
/// `&` goes first. Escaping it after the others would mangle the entities they
/// just introduced.
#[must_use]
pub fn escape_markup(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('\'', "&apos;")
        .replace('"', "&quot;")
}

/// A connection to whatever is showing notifications.
pub struct Bus {
    connection: zbus::blocking::Connection,
}

impl Bus {
    /// Connect to the session bus.
    ///
    /// # Errors
    /// Fails when there is no session bus to reach: no `DBUS_SESSION_BUS_ADDRESS`,
    /// or nothing listening on it.
    pub fn connect() -> Result<Self> {
        let connection = zbus::blocking::connection::Builder::session()
            .and_then(|builder| builder.method_timeout(METHOD_TIMEOUT).build())
            .map_err(|source| Error::Notifier { source })?;
        Ok(Self { connection })
    }

    /// Show `notification`.
    ///
    /// # Errors
    /// Fails when the daemon cannot be reached or refuses the notification.
    pub fn send(&self, notification: &Notification) -> Result<()> {
        let proxy = zbus::blocking::Proxy::new(&self.connection, BUS_NAME, OBJECT_PATH, INTERFACE)
            .map_err(|source| Error::Notifier { source })?;

        let mut hints: HashMap<&str, Value<'_>> = HashMap::new();
        hints.insert("urgency", Value::U8(notification.urgency.hint()));
        // dunst replaces a notification carrying the same tag rather than
        // stacking beside it, which is what makes a held-down volume key show
        // one moving bar instead of a column of them.
        hints.insert("x-dunst-stack-tag", Value::Str(notification.tag.into()));
        if let Some(percent) = notification.value {
            // The spec's `value` hint is signed; dunst reads it to draw the
            // progress bar the dunstrc already enables.
            hints.insert("value", Value::I32(i32::from(percent)));
        }

        let id = proxy
            .call::<_, _, u32>(
                "Notify",
                &(
                    APP_NAME,
                    // Replacement is the stack tag's job, so nothing is being
                    // replaced by id here.
                    0u32,
                    notification.icon,
                    // Escaped here at the boundary rather than by each caller.
                    // Every body that interpolates an SSID or a process name
                    // would otherwise have to remember, and the one that
                    // forgot would be the injection.
                    escape_markup(&notification.summary).as_str(),
                    escape_markup(&notification.body).as_str(),
                    &[] as &[&str],
                    hints,
                    notification.linger.milliseconds(),
                ),
            )
            .map_err(|source| Error::Notifier { source })?;

        tracing::debug!(
            id,
            tag = notification.tag,
            summary = %notification.summary,
            urgency = ?notification.urgency,
            linger_ms = notification.linger.milliseconds(),
            "shown"
        );
        Ok(())
    }
}
