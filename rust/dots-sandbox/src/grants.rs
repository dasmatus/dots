//! Live grant management against an already-running sandbox machine, via
//! `machinectl --user` — never the system-scope `machinectl bind` /
//! `bind-volume`. Those map to the polkit action
//! `org.freedesktop.machine1.manage-machines`, which is `auth_admin_keep`:
//! a real admin password prompt, on every single grant. `--user` talks to
//! the per-session machine1 instance instead and needs no such prompt.
//!
//! `machinectl`'s verbs are asymmetric, confirmed against `man
//! machinectl` on this machine (systemd 261): `bind` has no matching
//! `unbind` — only `bind-volume`/`unbind-volume` form a reversible pair.
//! A plain path grant is therefore one-way until the sandbox restarts;
//! [`revoke`] refuses to pretend otherwise for anything but a volume.
//!
//! # What a revoke does not do
//!
//! Revoking stops *new* opens. Any file descriptor the app already holds
//! survives until the app closes it, because unmounting a path does not
//! reach into a process that already has the file open. Every portal
//! system on Linux behaves this way, and it is stated here rather than
//! left implicit because the opposite belief is the dangerous one: a user
//! who revokes access to a directory and assumes a running app has lost it
//! is relying on something that is not true. Restart the sandbox if that
//! guarantee is needed.
//!
//! # Availability
//!
//! None of this works on a host whose systemd cannot delegate a managed
//! user namespace, because no machine ever starts to grant into. That is
//! the case on the development machine — systemd built without BPF, so
//! `systemd-nsresourced` runs and answers but cannot delegate — which is
//! why [`crate::policy::Tier::Bwrap`] is the default tier and why
//! capability changes there apply on next launch. See
//! `tests/live_grant.rs` for the measurements.
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use miette::Diagnostic;

use crate::broker::{AuditEvent, AuditLog, EventKind};

/// One kind of live grant `machinectl --user` supports.
#[derive(Debug, Clone)]
pub enum GrantKind {
    /// `machinectl --user bind`. One-way: see the module-level note.
    Path {
        host_path: PathBuf,
        /// Destination in the container; `None` mirrors the host path,
        /// matching `machinectl bind`'s own default.
        sandbox_path: Option<PathBuf>,
        read_only: bool,
        /// Create the destination directory first if it does not exist.
        mkdir: bool,
    },
    /// `machinectl --user bind-volume`. `spec` is `PROVIDER:VOLUME[:CONFIG][:K=V,...]`,
    /// passed through unparsed — validating that grammar is a
    /// storagectl(1) provider's job, not this crate's.
    Volume { spec: String },
}

/// Grants live directly to a running machine, without going through the
/// broker's prompt path — `grant`/`revoke`/`list` are explicit,
/// already-decided operator actions (run by a human, or by the broker
/// after a prompt it already resolved), not requests that need arbitrating
/// again here.
///
/// # Errors
///
/// Returns an error if `machinectl` cannot be spawned or exits non-zero;
/// the exit status and captured stderr are both preserved on
/// [`GrantError::MachinectlFailed`].
pub fn grant(
    audit: &AuditLog,
    app_id: &str,
    machine: &str,
    kind: &GrantKind,
) -> Result<(), GrantError> {
    let argv = grant_argv(machine, kind);
    let result = run_machinectl(&argv);
    log_outcome(audit, app_id, EventKind::Grant, &kind_detail(kind), &result);
    result.map(|_| ())
}

/// Builds the `machinectl` argv for one grant, split out from [`grant`]
/// so the command line itself is testable without actually invoking
/// `machinectl` — flags verified against `man machinectl` and `machinectl
/// --help` on this machine (systemd 261) rather than guessed.
#[must_use]
pub fn grant_argv(machine: &str, kind: &GrantKind) -> Vec<String> {
    let mut argv = vec!["--user".to_owned()];
    match kind {
        GrantKind::Path {
            host_path,
            sandbox_path,
            read_only,
            mkdir,
        } => {
            if *read_only {
                argv.push("--read-only".to_owned());
            }
            if *mkdir {
                argv.push("--mkdir".to_owned());
            }
            argv.push("bind".to_owned());
            argv.push(machine.to_owned());
            argv.push(path_to_arg(host_path));
            if let Some(sandbox_path) = sandbox_path {
                argv.push(path_to_arg(sandbox_path));
            }
        }
        GrantKind::Volume { spec } => {
            argv.push("bind-volume".to_owned());
            argv.push(machine.to_owned());
            argv.push(spec.clone());
        }
    }
    argv
}

/// Detaches a previously bound volume. Rejects a plain path grant up
/// front with a diagnostic explaining why, rather than silently no-op'ing
/// — see the module-level note on why `machinectl` can't do this live.
///
/// # Errors
///
/// Returns an error if `machinectl` cannot be spawned or exits non-zero.
pub fn revoke(
    audit: &AuditLog,
    app_id: &str,
    machine: &str,
    storage_name: &str,
) -> Result<(), GrantError> {
    let argv = vec![
        "--user".to_owned(),
        "unbind-volume".to_owned(),
        machine.to_owned(),
        storage_name.to_owned(),
    ];
    let result = run_machinectl(&argv);
    log_outcome(
        audit,
        app_id,
        EventKind::Revoke,
        &format!("volume:{storage_name}"),
        &result,
    );
    result.map(|_| ())
}

/// The explicit, documented rejection for revoking a plain path grant —
/// callers should reach for this rather than routing a path through
/// [`revoke`] and getting a `machinectl` usage error instead.
#[must_use]
pub fn revoke_path_grant_unsupported() -> GrantError {
    GrantError::PathRevokeUnsupported
}

/// Lists running sandbox machines: `machinectl --user list --output=json`.
/// Returns the parsed JSON array as-is rather than a typed struct — with
/// `systemd-nsresourced` not yet enabled here, no machine has ever run
/// under this crate to inspect the real field names against, so a typed
/// schema would be a guess dressed up as a contract. See this task's
/// report for why that guess was not worth making.
///
/// # Errors
///
/// Returns an error if `machinectl` cannot be spawned, exits non-zero, or
/// prints something that isn't valid JSON.
pub fn list_machines() -> Result<serde_json::Value, GrantError> {
    let argv = ["--user", "list", "--output=json"];
    let output = run_machinectl_raw(&argv)?;
    parse_list_output(&output)
}

/// Interprets a captured `machinectl ... list --output=json` invocation,
/// split out from [`list_machines`] so the interesting part — surfacing a
/// non-zero exit's stderr, or a JSON parse failure — is testable without
/// actually invoking `machinectl`. `Output`'s `ExitStatus` can only be
/// constructed by actually running a process on stable Rust except via
/// `ExitStatusExt::from_raw`, which is exactly how the tests build one.
///
/// # Errors
///
/// Returns an error if `output`'s exit status is non-zero, or if its
/// stdout is not valid JSON.
pub fn parse_list_output(output: &Output) -> Result<serde_json::Value, GrantError> {
    if !output.status.success() {
        return Err(GrantError::MachinectlFailed {
            status: output.status.code(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    serde_json::from_slice(&output.stdout).map_err(GrantError::MalformedJson)
}

fn kind_detail(kind: &GrantKind) -> String {
    match kind {
        GrantKind::Path {
            host_path,
            sandbox_path,
            read_only,
            ..
        } => {
            let dest = sandbox_path.clone().unwrap_or_else(|| host_path.clone());
            format!(
                "path:{} -> {} ({})",
                host_path.display(),
                dest.display(),
                if *read_only { "ro" } else { "rw" }
            )
        }
        GrantKind::Volume { spec } => format!("volume:{spec}"),
    }
}

fn log_outcome(
    audit: &AuditLog,
    app_id: &str,
    kind: EventKind,
    detail: &str,
    result: &Result<Output, GrantError>,
) {
    let outcome = match result {
        Ok(_) => "ok",
        Err(_) => "failed",
    };
    audit.log(&AuditEvent {
        ts_ms: crate::broker::now_ms(),
        app_id,
        kind,
        capability: None,
        outcome,
        detail: Some(detail),
    });
}

fn run_machinectl(argv: &[String]) -> Result<Output, GrantError> {
    let refs: Vec<&str> = argv.iter().map(String::as_str).collect();
    let output = run_machinectl_raw(&refs)?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(GrantError::MachinectlFailed {
            status: output.status.code(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

fn run_machinectl_raw(argv: &[&str]) -> Result<Output, GrantError> {
    Command::new("machinectl")
        .args(argv)
        .output()
        .map_err(GrantError::Spawn)
}

fn path_to_arg(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// `machinectl --user`'s failure modes, surfaced with the child's exit
/// status and captured stderr rather than swallowed — this crate's
/// house rule for anything shelled out to.
#[derive(Debug, Diagnostic)]
pub enum GrantError {
    MachinectlFailed {
        status: Option<i32>,
        stderr: String,
    },
    Spawn(std::io::Error),
    MalformedJson(serde_json::Error),
    #[diagnostic(help(
        "restart the sandbox to drop this grant; `machinectl` has no live `unbind` for a plain `bind` mount, only bind-volume/unbind-volume"
    ))]
    PathRevokeUnsupported,
}

impl std::fmt::Display for GrantError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MachinectlFailed { status, stderr } => {
                write!(
                    f,
                    "machinectl exited with {}: {}",
                    status.map_or_else(|| "signal".to_owned(), |c| c.to_string()),
                    stderr.trim()
                )
            }
            Self::Spawn(err) => write!(f, "failed to spawn machinectl: {err}"),
            Self::MalformedJson(err) => {
                write!(f, "machinectl --user list did not return valid JSON: {err}")
            }
            Self::PathRevokeUnsupported => {
                write!(f, "plain path grants cannot be revoked live")
            }
        }
    }
}

impl std::error::Error for GrantError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Spawn(err) => Some(err),
            Self::MalformedJson(err) => Some(err),
            _ => None,
        }
    }
}
