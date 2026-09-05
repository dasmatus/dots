//! Resolves an app's policy into a spawnable command, runs it, and keeps
//! our own process transparent to whoever invoked us: a signal sent to
//! us is relayed to the sandboxed child instead of silently swallowed,
//! and the child's exit status becomes our own.
use std::env;
use std::fs;
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{self, Command, ExitStatus};
use std::thread;

use miette::Diagnostic;
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

use crate::broker::{self, AuditEvent, AuditLog, EventKind, Interactivity};
use crate::merge_stub::{self, LaunchCtx, PolicyError};

/// What running the sandboxed app came to, once it has exited.
#[derive(Debug, Clone, Copy)]
pub struct LaunchOutcome {
    /// The process's own exit code: the child's own code, or
    /// 128+signal if a signal killed it instead — the same convention a
    /// shell uses, so scripts piping through this binary see something
    /// familiar rather than an opaque wrapper-specific scheme.
    pub exit_code: i32,
}

/// Resolves `app_id`'s policy, builds the command line via `spawn_argv`,
/// spawns it, forwards termination signals to it, and waits for it to
/// exit.
///
/// # Errors
///
/// Returns an error if the policy fails to resolve, `$HOME`/
/// `$XDG_RUNTIME_DIR` are unset, the resolved command line is empty, or
/// spawning/waiting on the sandboxed process itself fails. A non-zero
/// exit from the sandboxed program is not an error — see
/// [`LaunchOutcome::exit_code`].
pub fn run(
    app_id: &str,
    program: &str,
    args: &[String],
    interactivity: Interactivity,
    audit: &AuditLog,
) -> Result<LaunchOutcome, LaunchError> {
    let resolved = merge_stub::resolve_policy(app_id).map_err(LaunchError::Policy)?;

    if let Some(unconfined) = &resolved.unconfined {
        audit.log(&AuditEvent {
            ts_ms: broker::now_ms(),
            app_id,
            kind: EventKind::Unconfined,
            capability: None,
            outcome: "unconfined",
            detail: Some(&unconfined.reason),
        });
    }

    // Every capability gets a decision and an audit line, allow-by-policy
    // included — the dashboard should be able to show the whole picture,
    // not only the exceptions. See broker.rs for why `ask` never prompts
    // a non-interactive (wrapped CLI) app.
    for (capability, state) in &resolved.capabilities {
        let _ = broker::decide(audit, app_id, capability, *state, interactivity);
    }

    let ctx = build_ctx(app_id, program, args)?;
    let command_line = merge_stub::spawn_argv(&resolved, &ctx);
    spawn_and_wait(&command_line)
}

/// Assembles the injected context `spawn_argv` needs. Kept out of
/// `spawn_argv` itself (which stays pure, per the contract) — this is
/// where the actual filesystem/environment access happens.
fn build_ctx(app_id: &str, program: &str, args: &[String]) -> Result<LaunchCtx, LaunchError> {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(LaunchError::MissingEnv("HOME"))?;
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or(LaunchError::MissingEnv("XDG_RUNTIME_DIR"))?;
    // Invented convention, not read anywhere else in this crate yet: an
    // env var override for the dotfiles checkout, falling back to the
    // common `~/dots` clone location. `repo_root`'s actual purpose lives
    // inside `spawn_argv`, which this task does not own — confirm this
    // guess with the policy half at merge time.
    let repo_root =
        env::var_os("DOTS_SANDBOX_REPO_ROOT").map_or_else(|| home.join("dots"), PathBuf::from);
    let machine_name = sanitize_machine_name(app_id);
    let grant_share_dir = runtime_dir
        .join("dots-sandbox")
        .join(&machine_name)
        .join("grants");
    fs::create_dir_all(&grant_share_dir).map_err(LaunchError::Io)?;
    Ok(LaunchCtx {
        home,
        runtime_dir,
        repo_root,
        grant_share_dir,
        machine_name,
        program: program.to_owned(),
        args: args.to_vec(),
    })
}

/// `machinectl`/`systemd-nspawn` machine names follow hostname (DNS
/// label) rules: lower-case ASCII, digits and hyphens, at most 64
/// characters (see `man systemd.hostname`-adjacent docs referenced from
/// `man systemd-nspawn`). Appending our own pid keeps two concurrent
/// launches of the same app from colliding on one machine name.
fn sanitize_machine_name(app_id: &str) -> String {
    let cleaned: String = app_id
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let suffix = format!("-{}", process::id());
    let budget = 64usize.saturating_sub("dots-".len() + suffix.len());
    let truncated: String = cleaned.chars().take(budget.max(1)).collect();
    format!("dots-{truncated}{suffix}")
}

fn spawn_and_wait(argv: &[String]) -> Result<LaunchOutcome, LaunchError> {
    let (program, rest) = argv.split_first().ok_or(LaunchError::EmptyArgv)?;
    let mut child = Command::new(program)
        .args(rest)
        .spawn()
        .map_err(LaunchError::Spawn)?;
    let pid = child.id();

    // Relay SIGINT/SIGTERM/SIGHUP to the child. The main thread is about
    // to block in `wait()`, and `Signals::forever()` blocks too, so
    // relaying needs its own thread rather than a poll loop racing
    // `wait()`.
    let mut signals = Signals::new([SIGINT, SIGTERM, SIGHUP]).map_err(LaunchError::SignalSetup)?;
    let handle = signals.handle();
    let forwarder = thread::spawn(move || {
        for sig in signals.forever() {
            // Safety: `pid` is this process's own child, obtained from
            // `Child::id()` moments ago, and a bare `kill(2)` with a
            // forwarded signal number is the whole of the operation —
            // no memory is touched on the Rust side.
            unsafe {
                libc::kill(pid as libc::pid_t, sig);
            }
        }
    });

    let status = child.wait().map_err(LaunchError::Wait)?;
    handle.close();
    let _ = forwarder.join();

    Ok(LaunchOutcome {
        exit_code: exit_code_from_status(status),
    })
}

fn exit_code_from_status(status: ExitStatus) -> i32 {
    match status.code() {
        Some(code) => code,
        // No exit code means a signal killed the child; propagate the
        // conventional 128+signal so the caller can still tell which one,
        // the same convention a POSIX shell uses for a signal-terminated
        // job.
        None => 128 + status.signal().unwrap_or(0),
    }
}

/// Everything that can go wrong resolving and running an app, with the
/// shelled-out child's own exit status/stderr surfaced where relevant
/// rather than swallowed.
#[derive(Debug, Diagnostic)]
pub enum LaunchError {
    Policy(PolicyError),
    MissingEnv(&'static str),
    Io(io::Error),
    EmptyArgv,
    Spawn(io::Error),
    SignalSetup(io::Error),
    Wait(io::Error),
}

impl std::fmt::Display for LaunchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Policy(err) => write!(f, "resolving policy: {err}"),
            Self::MissingEnv(var) => write!(f, "${var} is not set"),
            Self::Io(err) => write!(f, "preparing launch context: {err}"),
            Self::EmptyArgv => write!(f, "spawn_argv returned an empty command line"),
            Self::Spawn(err) => write!(f, "failed to spawn sandboxed command: {err}"),
            Self::SignalSetup(err) => write!(f, "failed to install signal forwarding: {err}"),
            Self::Wait(err) => write!(f, "failed to wait for sandboxed command: {err}"),
        }
    }
}

impl std::error::Error for LaunchError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Policy(err) => Some(err),
            Self::Io(err) | Self::Spawn(err) | Self::SignalSetup(err) | Self::Wait(err) => {
                Some(err)
            }
            Self::MissingEnv(_) | Self::EmptyArgv => None,
        }
    }
}
