//! Resolves an app's policy into a spawnable command, runs it, and keeps
//! our own process transparent to whoever invoked us: a signal sent to
//! us is relayed to the sandboxed child instead of silently swallowed,
//! and the child's exit status becomes our own.
use std::env;
use std::fs;
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{self, Command, ExitStatus};
use std::thread;

use miette::Diagnostic;
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;

use crate::argv::{self, LaunchCtx};
use crate::broker::{self, AuditEvent, AuditLog, EventKind, Interactivity};
use crate::error::PolicyError;
use crate::policy::{self, PolicyFile, ResolvedApp};

/// Where `systemd-nsresourced` puts its Varlink socket once the service is
/// running. `systemd-nspawn`'s unprivileged `--user` scope talks to it
/// directly to claim a UID range, so without it the sandbox cannot start at
/// all — nspawn dies with "Failed to connect to nsresourced".
///
/// The service ships with systemd but NixOS never wires it up; this repo adds
/// a module that does, and that module only takes effect after a rebuild. So
/// between merging the sandbox and switching the system, every machine sits in
/// a window where this socket is absent.
const NSRESOURCED_SOCKET: &str = "/run/systemd/userdb/io.systemd.NamespaceResource";

/// Whether the host can actually run a sandbox right now.
///
/// Returns the reason it cannot, or `None` when it can.
fn sandbox_runtime_unavailable() -> Option<String> {
    // `DOTS_SANDBOX_REQUIRE_RUNTIME=1` suppresses the degradation and attempts
    // the sandbox regardless, following the same injection convention as
    // `$DOTS_SANDBOX_DEFAULTS` and friends. It can only ever make confinement
    // stricter — forcing an attempt that then fails loudly — so unlike
    // `DOTS_SANDBOX=0` it is not a way to get less isolation, and it is what
    // lets the audit tests exercise the sandboxed path on a host whose
    // nsresourced is not yet enabled.
    if env::var_os("DOTS_SANDBOX_REQUIRE_RUNTIME").is_some_and(|value| value == "1") {
        return None;
    }
    if Path::new(NSRESOURCED_SOCKET).exists() {
        return None;
    }
    Some(format!(
        "{NSRESOURCED_SOCKET} is absent, so systemd-nsresourced is not running \
         and systemd-nspawn cannot claim a UID range; enable the sandbox host \
         module and rebuild to confine this app"
    ))
}

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
/// An app resolved as [`ResolvedApp::Unconfined`] never reaches
/// `spawn_argv` at all: opting out of sandboxing means running `program`
/// directly, with no `systemd-nspawn`/`systemd-vmspawn` wrapper and no
/// per-capability decisions to log, only the one audit line recording the
/// exemption and its reason.
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
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(LaunchError::MissingEnv("HOME"))?;
    let resolved = resolve_policy(app_id, &home).map_err(LaunchError::Policy)?;

    match resolved {
        ResolvedApp::Unconfined { reason } => {
            audit.log(&AuditEvent {
                ts_ms: broker::now_ms(),
                app_id,
                kind: EventKind::Unconfined,
                capability: None,
                outcome: "unconfined",
                detail: Some(&reason),
            });
            spawn_and_wait(&unconfined_argv(program, args))
        }
        ResolvedApp::Sandboxed(resolved) => {
            // Degrade rather than break. A host that cannot start a sandbox
            // must still run the app: failing closed here would mean every
            // `nix run .#<app>` stops working the moment this wrapper lands
            // and stays broken until the user rebuilds, which is a far worse
            // outcome than an unconfined `clean`. The warning goes to stderr
            // and the audit log so the degradation is loud rather than
            // silent — an unconfined app that looks confined is the one
            // failure this must never have.
            if let Some(reason) = sandbox_runtime_unavailable() {
                eprintln!("dots-sandbox: running {app_id} UNCONFINED: {reason}");
                audit.log(&AuditEvent {
                    ts_ms: broker::now_ms(),
                    app_id,
                    kind: EventKind::Unconfined,
                    capability: None,
                    outcome: "unconfined_runtime_unavailable",
                    detail: Some(&reason),
                });
                return spawn_and_wait(&unconfined_argv(program, args));
            }

            // Every capability gets a decision and an audit line,
            // allow-by-policy included — the dashboard should be able to
            // show the whole picture, not only the exceptions. See
            // broker.rs for why `ask` never prompts a non-interactive
            // (wrapped CLI) app.
            for (capability, state) in &resolved.capabilities {
                let _ = broker::decide(audit, app_id, capability.as_str(), *state, interactivity);
            }

            let ctx = build_ctx(app_id, program, args, home)?;
            let command_line = argv::spawn_argv(&resolved, &ctx);
            spawn_and_wait(&command_line)
        }
    }
}

/// Loads `app_id`'s policy from disk: the defaults catalog at
/// `$DOTS_SANDBOX_DEFAULTS`, falling back to
/// `~/.config/dots-sandbox/defaults.json`, with
/// `~/.config/dots-sandbox/overrides.json` layered on top when it exists.
/// A missing overrides file is not an error — it is the normal state for
/// a user who has never touched the sandbox settings — mirroring exactly
/// how `dots-sandbox policy dump` resolves the same pair in `main.rs`.
///
/// # Errors
///
/// Returns an error if the defaults file (or an overrides file that does
/// exist) cannot be read or parsed, or if `app_id` cannot be resolved
/// against them — see [`policy::resolve_app`].
fn resolve_policy(app_id: &str, home_dir: &Path) -> Result<ResolvedApp, PolicyError> {
    let defaults_path = env::var_os("DOTS_SANDBOX_DEFAULTS")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir.join(".config/dots-sandbox/defaults.json"));
    let defaults = read_policy_file(&defaults_path)?;

    let overrides_path = home_dir.join(".config/dots-sandbox/overrides.json");
    let overrides = if overrides_path.exists() {
        read_policy_file(&overrides_path)?
    } else {
        policy::empty_overrides(defaults.version)
    };

    policy::resolve_app(&defaults, &overrides, app_id, home_dir)
}

fn read_policy_file(path: &Path) -> Result<PolicyFile, PolicyError> {
    let contents = fs::read_to_string(path).map_err(|source| PolicyError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    policy::parse_policy_file(path, &contents)
}

/// The command line for an unconfined app: `program` and `args`,
/// completely unwrapped. This is the one case `spawn_argv` never runs at
/// all, since there is no sandboxing left to translate into flags.
fn unconfined_argv(program: &str, args: &[String]) -> Vec<String> {
    std::iter::once(program.to_owned())
        .chain(args.iter().cloned())
        .collect()
}

/// Assembles the injected context `spawn_argv` needs. Kept out of
/// `spawn_argv` itself (which stays pure, per the contract) — this is
/// where the actual filesystem/environment access happens.
fn build_ctx(
    app_id: &str,
    program: &str,
    args: &[String],
    home_dir: PathBuf,
) -> Result<LaunchCtx, LaunchError> {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or(LaunchError::MissingEnv("XDG_RUNTIME_DIR"))?;
    // Invented convention, not read anywhere else in this crate yet: an
    // env var override for the dotfiles checkout, falling back to the
    // common `~/dots` clone location.
    let repo_root =
        env::var_os("DOTS_SANDBOX_REPO_ROOT").map_or_else(|| home_dir.join("dots"), PathBuf::from);
    let machine_name = sanitize_machine_name(app_id);
    let grant_share_dir = runtime_dir
        .join("dots-sandbox")
        .join(&machine_name)
        .join("grants");
    fs::create_dir_all(&grant_share_dir).map_err(LaunchError::Io)?;

    // Same invented-convention story as `repo_root`: a later Nix task is
    // what actually builds the container rootfs, the sandbox kernel and
    // its firmware descriptor and wires their store paths in through
    // these three env vars. Until it does, a `container`/`vm`-tier app
    // resolves to a command line that fails fast and loudly —
    // `systemd-nspawn`/`systemd-vmspawn` refusing a directory or kernel
    // image that does not exist — rather than to a silently wrong one.
    let container_rootfs = env::var_os("DOTS_SANDBOX_CONTAINER_ROOTFS").map_or_else(
        || PathBuf::from("/var/lib/dots-sandbox/container-rootfs"),
        PathBuf::from,
    );
    let vm_kernel = env::var_os("DOTS_SANDBOX_VM_KERNEL").map_or_else(
        || PathBuf::from("/var/lib/dots-sandbox/vmlinuz-sandbox"),
        PathBuf::from,
    );
    let vm_firmware = env::var_os("DOTS_SANDBOX_VM_FIRMWARE").map_or_else(
        || PathBuf::from("/var/lib/dots-sandbox/OVMF_CODE.fd"),
        PathBuf::from,
    );

    Ok(LaunchCtx {
        home_dir,
        runtime_dir,
        repo_root,
        grant_share_dir,
        machine_name,
        container_rootfs,
        vm_kernel,
        vm_firmware,
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
