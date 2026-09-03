//! Provider credentials, read out of the login keyring through
//! `secret-tool`, lazily and with a deadline.
//!
//! Both of those words are load-bearing, and `nix/home/edupage-mcp.nix`
//! documents why at length. The short version: `secret-tool lookup` unlocks
//! the collection unconditionally, there is no flag to decline the prompt,
//! and libsecret resolves that prompt through a plain `g_main_loop_run` with
//! no deadline and no cancellable. So an unanswered dialog blocks the caller
//! for as long as nobody answers it.
//!
//! This machine logs in through greetd, and `nix/modules/core.nix` turns PAM
//! keyring unlock on for the `login` service only, so the collection really
//! is locked on a cold boot. A lookup at daemon startup would therefore hang
//! the daemon on every cold boot, before the socket exists, with the pane
//! seeing nothing at all. So:
//!
//! - **Lazy.** Nothing here runs until a provider backend is actually
//!   selected for a turn. The registry reports a provider as `unconfigured`
//!   with a detail line saying the credential is read on first use, rather
//!   than probing to find out.
//! - **Capped.** Every lookup gets [`DEFAULT_TIMEOUT`]. The cap is
//!   deliberately far too short to type a password into a dialog: a backend
//!   that says "unavailable" in ten seconds beats one that never answers.
//! - **Never fatal.** A missing key, a locked collection and a machine with
//!   no `secret-tool` at all are the same outcome here, [`Secret::Missing`],
//!   and the caller turns that into a backend that cannot run rather than
//!   into a panic or a stall.
//!
//! The cap is enforced in-process rather than by shelling to coreutils'
//! `timeout`, which is what the Nix wrapper does. Same semantics, one fewer
//! binary that has to be on `PATH` for the deadline to exist at all, and the
//! kill is this process's own rather than a signal it has to trust another
//! process to send.
//!
//! A key never reaches an event, the store or a log line. The only thing
//! that leaves this module is the secret itself, handed to the one backend
//! that asked for it.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use tokio::process::Command;

/// How long one lookup may take before it is killed.
///
/// Ten seconds, the same cap `nix/home/edupage-mcp.nix:160` established for
/// the same reason.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// The program that reads the keyring.
const DEFAULT_PROGRAM: &str = "secret-tool";

/// The `service` attribute every dots-ask key is stored under.
pub const SERVICE: &str = "dots-ask";

/// What a lookup found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Secret {
    /// The keyring had it.
    Found(String),
    /// The keyring did not, and the caller should report the backend as
    /// unavailable.
    ///
    /// The string says which of the several ways it went missing happened,
    /// so the pane's `detail` line can be specific: no such item, a locked
    /// collection that ran out the clock, or no `secret-tool` at all.
    Missing(String),
}

impl Secret {
    /// The secret itself, or `None` when the lookup came up empty.
    #[must_use]
    pub fn value(&self) -> Option<&str> {
        match self {
            Self::Found(value) => Some(value),
            Self::Missing(_) => None,
        }
    }

    /// Why the lookup came up empty, or `None` when it did not.
    #[must_use]
    pub fn detail(&self) -> Option<&str> {
        match self {
            Self::Found(_) => None,
            Self::Missing(reason) => Some(reason),
        }
    }
}

/// Reads provider credentials out of the login keyring, once each.
///
/// The cache is what keeps the laziness from costing a lookup per turn, and
/// it caches a miss as well as a hit. A person who stores a key while the
/// daemon is running has to restart it, which is the same deal every other
/// keyring consumer in this config offers, and it beats re-running a lookup
/// that can block for ten seconds on every send.
pub struct SecretStore {
    program: OsString,
    leading: Vec<OsString>,
    timeout: Duration,
    cache: Mutex<BTreeMap<String, Secret>>,
}

impl Default for SecretStore {
    fn default() -> Self {
        Self::new(DEFAULT_PROGRAM, DEFAULT_TIMEOUT)
    }
}

impl SecretStore {
    /// A store that runs `program` and gives each lookup `timeout`.
    ///
    /// Both are parameters so a test can point at a fake lookup command with
    /// a deadline short enough to assert against. Production uses
    /// [`SecretStore::default`], which is `secret-tool` and
    /// [`DEFAULT_TIMEOUT`].
    #[must_use]
    pub fn new(program: impl Into<OsString>, timeout: Duration) -> Self {
        Self::with_prefix(program, Vec::new(), timeout)
    }

    /// A store that runs `program` with `leading` before the lookup
    /// arguments.
    ///
    /// The shape exists because a lookup command is not always a bare
    /// binary. `nix/home/edupage-mcp.nix` already wraps `secret-tool` in a
    /// shell wrapper, and pointing this at one means naming the arguments
    /// that come before `lookup`.
    ///
    /// It is also what lets a test drive `/bin/sh -c <script> --` rather than
    /// writing an executable to a temporary directory. That matters more
    /// than it sounds: several tests writing and then exec'ing their own
    /// scripts in one process race on `ETXTBSY`, because a `fork` for one
    /// test's spawn inherits the still-open write descriptor for another
    /// test's file, and the kernel refuses to exec a file anybody holds open
    /// for writing.
    #[must_use]
    pub fn with_prefix(
        program: impl Into<OsString>,
        leading: Vec<OsString>,
        timeout: Duration,
    ) -> Self {
        Self {
            program: program.into(),
            leading,
            timeout,
            cache: Mutex::new(BTreeMap::new()),
        }
    }

    /// The credential stored under `attribute`, looking it up at most once.
    ///
    /// This is `async` because the deadline is, and because it must never be
    /// called from inside the hub's lock. The lock covers a whole frame and
    /// holds a `std::sync::Mutex`, so an await under it would not compile;
    /// the backend task calls this as its first step instead, after
    /// `Backend::start` has already returned.
    pub async fn lookup(&self, attribute: &str) -> Secret {
        if let Some(cached) = self.cached(attribute) {
            return cached;
        }
        let found = self.run_lookup(attribute).await;
        if let Ok(mut cache) = self.cache.lock() {
            cache.insert(attribute.to_owned(), found.clone());
        }
        found
    }

    /// Whether a lookup for `attribute` has already run.
    ///
    /// The registry uses this to describe a provider's state without causing
    /// a lookup, which is the whole laziness rule in one method.
    #[must_use]
    pub fn cached(&self, attribute: &str) -> Option<Secret> {
        self.cache
            .lock()
            .ok()
            .and_then(|cache| cache.get(attribute).cloned())
    }

    /// Run one `secret-tool lookup`, killing it when the deadline passes.
    async fn run_lookup(&self, attribute: &str) -> Secret {
        let child = match Command::new(&self.program)
            .args(&self.leading)
            .arg("lookup")
            .arg("service")
            .arg(SERVICE)
            .arg("attribute")
            .arg(attribute)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(child) => child,
            Err(err) => {
                return Secret::Missing(format!(
                    "cannot run {}: {err}",
                    self.program.to_string_lossy()
                ))
            }
        };

        let output = match tokio::time::timeout(self.timeout, child.wait_with_output()).await {
            Ok(Ok(output)) => output,
            Ok(Err(err)) => return Secret::Missing(format!("keyring lookup failed: {err}")),
            Err(_) => {
                // The child is killed by `kill_on_drop` as this future is
                // dropped. A lookup that ran out the clock is a locked
                // collection with a prompt nobody answered, which is exactly
                // the cold-boot case the cap exists for.
                tracing::warn!(
                    attribute,
                    seconds = self.timeout.as_secs(),
                    "keyring lookup timed out; treating the credential as absent"
                );
                return Secret::Missing(format!(
                    "the login keyring did not answer within {}s; unlock it and restart dots-ask",
                    self.timeout.as_secs()
                ));
            }
        };

        if !output.status.success() {
            return Secret::Missing(format!(
                "no {SERVICE}/{attribute} in the login keyring; store one with secret-tool"
            ));
        }
        let value = String::from_utf8_lossy(&output.stdout)
            .trim_end_matches('\n')
            .to_owned();
        if value.is_empty() {
            return Secret::Missing(format!("{SERVICE}/{attribute} in the keyring is empty"));
        }
        Secret::Found(value)
    }
}
