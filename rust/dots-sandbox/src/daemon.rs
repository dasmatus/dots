//! The session-bus daemon: `dots-sandbox daemon`.
//!
//! Exists because the permissions UI was shelling out to `dots-sandbox
//! catalog` on every read. That works, and it is wrong in two ways that
//! compound: a process spawn per repaint, and no way for the page to learn
//! that a policy changed without polling. A long-lived owner of the policy
//! answers both — the UI reads once and subscribes.
//!
//! # What this deliberately does not do
//!
//! **`run` never touches the bus.** Not as an optimisation: a launcher that
//! depends on a daemon fails closed when the daemon is down, and "no app
//! starts because a background service crashed" is strictly worse than
//! having no daemon at all. `dots-sandbox run` stays a self-contained exec
//! that reads the policy files directly, exactly as it did before this
//! module existed, and `DOTS_SANDBOX=0` keeps bypassing everything.
//!
//! So the split is: the daemon owns the *stateful* half — the reads the UI
//! makes, the writes it makes back, and the change notification between
//! them — while launching stays stateless and independent.
//!
//! **It does not confine anything.** A daemon is bookkeeping. What actually
//! confines an app is the wrapper, the policy, and the namespace the spawn
//! binaries set up. Running this service does not make the machine safer by
//! itself, and the unit's description says so rather than implying
//! otherwise.
//!
//! # Bus name and activation
//!
//! `org.dots.Sandbox1` on the **session** bus, not the system bus. Every
//! path it touches is the user's own (`~/.config/dots-sandbox/`), nothing
//! needs root, and putting it on the system bus would mean a polkit policy
//! and an admin prompt for what is a per-user preference. That is the same
//! reasoning that kept the whole sandbox in the user session rather than
//! going through `machinectl`'s `auth_admin_keep` action.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use zbus::{connection, interface, object_server::SignalEmitter};

use crate::catalog;
use crate::error::PolicyError;
use crate::policy::{self, PolicyFile, PolicyState, ResolvedPolicySet};
use crate::report;

/// The bus name, object path and interface all share this stem.
pub const BUS_NAME: &str = "org.dots.Sandbox1";
/// The single object this service exports.
pub const OBJECT_PATH: &str = "/org/dots/Sandbox1";

/// Everything the daemon needs to answer a call, resolved once at startup.
///
/// Held behind a `Mutex` rather than reloaded per call: a call that
/// re-reads two JSON files from disk is not meaningfully cheaper than the
/// process spawn this replaced, and the whole point was to stop doing that
/// work on every repaint.
pub struct Sandbox {
    home: PathBuf,
    defaults: PathBuf,
    overrides: PathBuf,
    resolved: Mutex<ResolvedPolicySet>,
}

impl Sandbox {
    /// Read both policy layers and resolve them.
    ///
    /// # Errors
    ///
    /// Returns the underlying [`PolicyError`] when either file is missing,
    /// unparseable, or fails validation — the daemon refuses to start on a
    /// broken policy rather than serving a half-resolved one, because every
    /// answer it gives would otherwise be quietly wrong.
    pub fn new(home: PathBuf, defaults: PathBuf, overrides: PathBuf) -> Result<Self, PolicyError> {
        let resolved = resolve(&home, &defaults, &overrides)?;
        Ok(Self {
            home,
            defaults,
            overrides,
            resolved: Mutex::new(resolved),
        })
    }

    /// Re-read and re-resolve, replacing what is held.
    fn reload(&self) -> Result<(), PolicyError> {
        let fresh = resolve(&self.home, &self.defaults, &self.overrides)?;
        // A poisoned lock means a previous call panicked while holding it.
        // Recovering the value is correct here: the guarded data is a plain
        // resolved policy with no invariant a panic could have broken
        // halfway, and refusing to serve for the rest of the process's life
        // would be a worse failure than continuing.
        let mut guard = self.resolved.lock().unwrap_or_else(|poisoned| {
            tracing::warn!("recovering a poisoned policy lock");
            poisoned.into_inner()
        });
        *guard = fresh;
        Ok(())
    }

    fn with_resolved<T>(&self, f: impl FnOnce(&ResolvedPolicySet) -> T) -> T {
        let guard = self.resolved.lock().unwrap_or_else(|poisoned| {
            tracing::warn!("recovering a poisoned policy lock");
            poisoned.into_inner()
        });
        f(&guard)
    }
}

/// Read, merge and resolve both policy layers.
fn resolve(
    home: &Path,
    defaults: &Path,
    overrides: &Path,
) -> Result<ResolvedPolicySet, PolicyError> {
    let defaults_file = read_policy(defaults)?;
    // A missing overrides file is the normal state on a fresh machine, not
    // an error: it means "no user overrides yet".
    let overrides_file = if overrides.exists() {
        read_policy(overrides)?
    } else {
        policy::empty_overrides(defaults_file.version)
    };
    policy::resolve_all(&defaults_file, &overrides_file, home)
}

fn read_policy(path: &Path) -> Result<PolicyFile, PolicyError> {
    let contents = std::fs::read_to_string(path).map_err(|source| PolicyError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    policy::parse_policy_file(path, &contents)
}

/// Turn any internal failure into a D-Bus error.
///
/// The message carries the diagnostic's own text rather than a generic
/// "call failed", because the caller is a UI that will show it to a person
/// who then has to fix the underlying file.
fn to_fdo(err: &PolicyError) -> zbus::fdo::Error {
    zbus::fdo::Error::Failed(format!("{:?}", miette::Report::msg(err.to_string())))
}

#[interface(name = "org.dots.Sandbox1")]
impl Sandbox {
    /// The permissions page's whole model, as the JSON `catalog --json`
    /// prints.
    ///
    /// Returned as a string rather than a marshalled D-Bus structure on
    /// purpose: the shape is already defined, versioned and tested as JSON
    /// (`catalog::Catalog`), and re-expressing it as a nested D-Bus
    /// signature would be a second schema to keep in step with the first.
    /// The QML side parses JSON either way.
    fn catalog(&self) -> String {
        let cat = self.with_resolved(|resolved| catalog::scan(&self.home, resolved));
        serde_json::to_string(&cat).unwrap_or_else(|err| {
            tracing::error!(error = %err, "failed to serialize the catalog");
            // A parse failure on the client is a better outcome than a
            // silent empty catalog that reads as "no apps are sandboxed".
            String::new()
        })
    }

    /// The privacy and hardware-security dashboard.
    ///
    /// Reads live system state on every call rather than anything cached,
    /// so it genuinely does not need `self` — but a `#[interface]` method
    /// must take a receiver to be exported at all, so clippy's
    /// "make it an associated function" would un-export it. Allowed rather
    /// than restructured for that reason.
    #[allow(clippy::unused_self)]
    fn report(&self) -> String {
        let collected = report::collect();
        serde_json::to_string(&collected).unwrap_or_else(|err| {
            tracing::error!(error = %err, "failed to serialize the report");
            String::new()
        })
    }

    /// Set one capability's state for one app, writing it to the user's
    /// overrides file, then re-resolve and announce the change.
    ///
    /// # Errors
    ///
    /// Fails when `state` is not one of `allow`/`ask`/`deny`, when the app
    /// is unknown, or when the overrides file cannot be written.
    async fn set_capability(
        &self,
        app_id: &str,
        capability: &str,
        state: &str,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        // `allow-once` is rejected here for the same reason it has no
        // variant to parse into: it is a prompt answer, never a persisted
        // state, and writing it would quietly turn "once" into "always".
        let parsed = match state {
            "allow" => PolicyState::Allow,
            "ask" => PolicyState::Ask,
            "deny" => PolicyState::Deny,
            other => {
                return Err(zbus::fdo::Error::InvalidArgs(format!(
                    "{other:?} is not a persistable state; expected allow, ask or deny \
                     (allow-once is a prompt answer and is never written to disk)"
                )))
            }
        };

        write_override(&self.overrides, app_id, capability, parsed).map_err(|err| to_fdo(&err))?;
        self.reload().map_err(|err| to_fdo(&err))?;

        // Emitted after the reload, never before: a client that re-reads on
        // this signal must find the new value already in place, or it will
        // race the write it was told about and render the old state.
        Self::policy_changed(&emitter).await?;
        Ok(())
    }

    /// Emitted whenever the resolved policy changes, so a UI re-reads
    /// instead of polling. Carries no payload: the catalog is one call
    /// away, and a partial payload would be a second representation of the
    /// same state that could disagree with it.
    #[zbus(signal)]
    async fn policy_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// Merge one capability state into the overrides file on disk.
///
/// Read-modify-write of the whole document rather than an append: the file
/// is a layered policy, not a log, and the user may have edited it by hand.
fn write_override(
    path: &Path,
    app_id: &str,
    capability: &str,
    state: PolicyState,
) -> Result<(), PolicyError> {
    let mut file = if path.exists() {
        read_policy(path)?
    } else {
        policy::empty_overrides(policy::SUPPORTED_VERSION)
    };

    file.apps
        .entry(app_id.to_string())
        .or_default()
        .caps
        .insert(capability.to_string(), state);

    let serialized = serde_json::to_string_pretty(&file).map_err(|source| PolicyError::Parse {
        path: path.to_path_buf(),
        source,
    })?;

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|source| PolicyError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    std::fs::write(path, serialized + "\n").map_err(|source| PolicyError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Claim the bus name and serve until the process is stopped.
///
/// # Errors
///
/// Fails if the session bus is unreachable or the name is already owned by
/// another instance. Both are worth failing on rather than retrying: the
/// first means there is no session to serve, and the second means a daemon
/// is already running, which systemd's own restart handling should resolve
/// rather than two instances fighting over the same overrides file.
pub async fn serve(sandbox: Sandbox) -> zbus::Result<connection::Connection> {
    connection::Builder::session()?
        .name(BUS_NAME)?
        .serve_at(OBJECT_PATH, sandbox)?
        .build()
        .await
}
