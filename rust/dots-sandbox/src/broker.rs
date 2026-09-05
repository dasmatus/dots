//! Decides the fate of every capability a resolved policy attaches to an
//! app, and writes the audit trail the privacy dashboard reads — every
//! capability request, grant and denial, per the brief.
//!
//! The one correctness property this module exists to enforce: a wrapped
//! CLI app must never block on a prompt. `nix run .#nix-lint` running in
//! CI or over SSH has no human to answer a prompt, so an `ask` capability
//! on a [`Interactivity::NonInteractive`] app is denied outright, without
//! ever touching the prompt path below. Only [`Interactivity::Interactive`]
//! apps (GUI wrappers) reach it, and even then a hard timeout applies —
//! a prompt that can hang is the exact failure mode being designed
//! against, not an edge case to tolerate.
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::policy::PolicyState;

/// Generous enough that a human glancing at their screen can answer, short
/// enough that a launch never wedges waiting for one who isn't there.
const PROMPT_TIMEOUT: Duration = Duration::from_secs(20);

/// Whether the app being launched can be prompted at all. Not part of the
/// policy contract (`ResolvedPolicy` describes capabilities, not app
/// kind) — plumbed in separately as a `run --interactive` flag; see this
/// task's report for why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Interactivity {
    /// A GUI-wrapped app: may show a prompt.
    Interactive,
    /// A wrapped CLI app: must never prompt, ever.
    NonInteractive,
}

/// The resolved fate of one capability request. Every variant here is a
/// distinct audit outcome, not just a yes/no, because the privacy
/// dashboard should be able to tell "policy said no" apart from "asked
/// and the user said no" apart from "wanted to ask but couldn't."
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    AllowedByPolicy,
    DeniedByPolicy,
    PromptApproved,
    PromptDenied,
    PromptTimedOut,
    /// `ask`, but the app is not allowed to prompt at all.
    DeniedNonInteractive,
    /// `ask`, interactive, but no Wayland session and no TTY either.
    DeniedNoPromptChannel,
}

impl Outcome {
    fn as_str(self) -> &'static str {
        match self {
            Self::AllowedByPolicy => "allowed_by_policy",
            Self::DeniedByPolicy => "denied_by_policy",
            Self::PromptApproved => "prompt_approved",
            Self::PromptDenied => "prompt_denied",
            Self::PromptTimedOut => "prompt_timed_out",
            Self::DeniedNonInteractive => "denied_non_interactive",
            Self::DeniedNoPromptChannel => "denied_no_prompt_channel",
        }
    }
}

/// Decide the fate of one capability and log the decision. Called for
/// every capability in a resolved policy, not only the interesting ones —
/// "every capability request... gets logged" per the brief, and an
/// allow-by-policy line is what lets the dashboard show a complete
/// picture rather than only the exceptions.
#[must_use]
pub fn decide(
    audit: &AuditLog,
    app_id: &str,
    capability: &str,
    state: PolicyState,
    interactivity: Interactivity,
) -> Outcome {
    let outcome = match (state, interactivity) {
        (PolicyState::Allow, _) => Outcome::AllowedByPolicy,
        (PolicyState::Deny, _) => Outcome::DeniedByPolicy,
        (PolicyState::Ask, Interactivity::NonInteractive) => Outcome::DeniedNonInteractive,
        (PolicyState::Ask, Interactivity::Interactive) => prompt(app_id, capability),
    };
    audit.log(&AuditEvent {
        ts_ms: now_ms(),
        app_id,
        kind: EventKind::CapabilityRequest,
        capability: Some(capability),
        outcome: outcome.as_str(),
        detail: None,
    });
    outcome
}

/// Ask the user, GUI first, falling back to a TTY, denying if neither
/// channel exists. Every path here is bounded by [`PROMPT_TIMEOUT`].
/// Senses the real environment and delegates the actual precedence
/// decision to [`resolve_prompt`], which is what tests exercise directly
/// — this function's own job is only to gather real channel replies,
/// which in this sandboxed build environment means no `qs` binary and no
/// TTY, and so isn't itself something an automated test can cover
/// meaningfully; see this crate's tests for the split.
fn prompt(app_id: &str, capability: &str) -> Outcome {
    let has_wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let gui_reply = if has_wayland {
        gui_prompt(app_id, capability, PROMPT_TIMEOUT)
    } else {
        None
    };
    let is_tty = io::stdin().is_terminal();
    // Don't block on a TTY read the GUI channel already answered.
    let need_tty = is_tty && !(has_wayland && gui_reply.is_some());
    let tty_reply = if need_tty {
        tty_prompt(capability, PROMPT_TIMEOUT)
    } else {
        None
    };
    resolve_prompt(has_wayland, gui_reply, is_tty, tty_reply)
}

/// The channel-selection precedence, decoupled from actually calling out
/// to `qs`/stdin so it can be tested without either: a Wayland session
/// tries the GUI prompt first; if that channel doesn't exist, the call
/// itself failed, or there is no Wayland session at all, an interactive
/// TTY is tried next; with neither, the request is denied. `gui_reply`/
/// `tty_reply` being `None` means "this channel gave no answer" — either
/// because it was never tried (the corresponding `has_*`/`is_*` flag was
/// false) or because it was tried and timed out; both cases fall through
/// the same way.
#[must_use]
pub fn resolve_prompt(
    has_wayland: bool,
    gui_reply: Option<bool>,
    is_tty: bool,
    tty_reply: Option<bool>,
) -> Outcome {
    if has_wayland {
        match gui_reply {
            Some(true) => return Outcome::PromptApproved,
            Some(false) => return Outcome::PromptDenied,
            // The GUI channel exists but the call itself failed or hung —
            // fall through to the TTY rather than giving up immediately.
            None => {}
        }
    }
    if is_tty {
        return match tty_reply {
            Some(true) => Outcome::PromptApproved,
            Some(false) => Outcome::PromptDenied,
            None => Outcome::PromptTimedOut,
        };
    }
    Outcome::DeniedNoPromptChannel
}

/// Calls out to quickshell's IPC bus, per the brief: `qs ipc call
/// sandboxprompt …`. The exact function name and reply encoding are this
/// task's own guess (the QML side lives in another task's territory) —
/// `ask <capability>` returning a bare `true`/`false` on stdout, which is
/// what `qs ipc call` prints for a boolean-returning QML function.
/// Returns `None` if the call could not be made or timed out, distinct
/// from an explicit `false` reply.
fn gui_prompt(app_id: &str, capability: &str, timeout: Duration) -> Option<bool> {
    // `app_id` is passed as well as `capability` because the dialog's
    // "allow always" writes an override, and an override is per app: without
    // knowing which app asked, that answer could only be recorded globally,
    // which is a far broader grant than the user believes they are giving.
    // Prompt.qml's handler already takes `ask(appId, capability)`.
    let (reader, writer) = io::pipe().ok()?;

    let mut command = Command::new("qs");
    command
        .args(["ipc", "call", "sandboxprompt", "ask", app_id, capability])
        .stdin(Stdio::null())
        .stdout(writer)
        .stderr(Stdio::null());
    let mut child = command.spawn().ok()?;

    // Drop the command, and with it the parent's copy of the pipe's write
    // end. The child holds its own dup; while ours stays open the read end
    // never sees EOF, so the reader below would block for the whole timeout
    // even after `qs` has answered and exited — turning a prompt that works
    // into one that always appears to hang. `Stdio::piped()` hides this by
    // closing the parent's end itself; an explicit pipe hands that
    // responsibility over.
    drop(command);

    let stdout = read_with_timeout(reader, &mut child, timeout)?;
    Some(stdout.trim() == "true")
}

/// TTY fallback for when there is no Wayland session (headless SSH, a
/// bare console) but a human is still at the keyboard.
fn tty_prompt(capability: &str, timeout: Duration) -> Option<bool> {
    eprint!("dots-sandbox: allow capability {capability:?}? [y/N] ");
    let _ = io::stderr().flush();
    let (tx, rx) = mpsc::channel();
    // `read_line` has no deadline of its own, so the wait for input runs
    // on its own thread; the timeout below fires either way. If nobody
    // ever answers, this thread simply never finishes — accepted, since
    // std has no way to cancel a blocking read, and the alternative is a
    // launch that can hang forever, which is exactly what this design
    // exists to avoid.
    thread::spawn(move || {
        let mut line = String::new();
        let _ = io::stdin().read_line(&mut line);
        let _ = tx.send(line);
    });
    let line = rx.recv_timeout(timeout).ok()?;
    Some(matches!(line.trim().to_lowercase().as_str(), "y" | "yes"))
}

/// Reads a child's stdout to completion, but gives up and kills it after
/// `timeout`. `Child::wait_with_output` has no deadline parameter, and a
/// wedged `qs` call must not wedge the launch with it — so the read runs
/// on a dedicated thread and the timeout is enforced with a channel
/// rather than polling `try_wait` in a sleep loop.
fn read_with_timeout(
    mut reader: io::PipeReader,
    child: &mut Child,
    timeout: Duration,
) -> Option<String> {
    // The read happens on its own thread and comes back over a channel,
    // because `read_to_string` has no timeout of its own: a `qs` that hangs
    // rather than exiting would block this call forever. `recv_timeout` is
    // what bounds it, and the thread is what leaves us free to bound it —
    // the module's whole promise is that no prompt can hang.
    //
    // A leaked thread on the timeout path is deliberate. It is parked in a
    // read on a pipe whose write end dies with the child we kill below, so
    // it wakes, finds EOF, sends into a dropped receiver, and exits.
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = String::new();
        let _ = reader.read_to_string(&mut buf);
        let _ = tx.send(buf);
    });
    if let Ok(buf) = rx.recv_timeout(timeout) {
        let _ = child.wait();
        Some(buf)
    } else {
        let _ = child.kill();
        let _ = child.wait();
        None
    }
}

/// What kind of event an [`AuditEvent`] records.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    CapabilityRequest,
    Grant,
    Revoke,
    /// The policy opted this app out of sandboxing entirely; see
    /// [`crate::policy::ResolvedApp::Unconfined`].
    Unconfined,
}

/// One line of the audit trail. Serialized as a single JSON object per
/// line (JSON Lines) — see [`AuditLog`] for the file format and location.
#[derive(Debug, Serialize)]
pub struct AuditEvent<'a> {
    /// Milliseconds since the Unix epoch: sortable, and trivially
    /// convertible with `new Date(ts_ms)` in the QML/JS dashboard that
    /// consumes this log, without pulling in a date-parsing dependency
    /// on either side.
    pub ts_ms: u128,
    pub app_id: &'a str,
    pub kind: EventKind,
    pub capability: Option<&'a str>,
    /// Free-vocabulary outcome string; see [`Outcome::as_str`] for
    /// capability requests and `grants.rs` for grant/revoke's own
    /// vocabulary. Deliberately a plain string rather than a shared enum
    /// so the two domains don't have to agree on one closed set of
    /// outcomes.
    pub outcome: &'a str,
    pub detail: Option<&'a str>,
}

pub(crate) fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

/// Appends [`AuditEvent`]s to a JSON Lines file the privacy dashboard
/// tails. A logging failure never aborts the launch it's describing —
/// losing an audit line is regrettable, denying a capability request
/// because `/var` briefly ran out of space would be worse — so failures
/// only reach `tracing`, never the caller.
pub struct AuditLog {
    path: PathBuf,
}

impl AuditLog {
    /// `$XDG_STATE_HOME/dots-sandbox/audit.jsonl`, falling back to
    /// `$HOME/.local/state` when unset, matching the XDG base directory
    /// spec's home for persistent-but-not-quite-data log-like state.
    pub fn open_default() -> Self {
        let state_home = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        Self {
            path: state_home.join("dots-sandbox").join("audit.jsonl"),
        }
    }

    pub fn with_path(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn log(&self, event: &AuditEvent<'_>) {
        if let Err(err) = self.try_log(event) {
            tracing::warn!(error = %err, path = %self.path.display(), "failed to write audit log line");
        }
    }

    fn try_log(&self, event: &AuditEvent<'_>) -> io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut line = serde_json::to_string(event)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        line.push('\n');
        // A single JSON line here is well under the kernel's atomic
        // O_APPEND write guarantee on a local filesystem, so concurrent
        // sandboxed apps logging at once can't interleave partial lines.
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(line.as_bytes())
    }
}
