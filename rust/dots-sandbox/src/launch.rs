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

/// Whether the host can run the tier this policy asks for.
///
/// Returns the reason it cannot, or `None` when it can. A caller that gets
/// a reason degrades to running the app unconfined rather than refusing to
/// launch it at all — see [`run`].
fn tier_unavailable(tier: policy::Tier) -> Option<String> {
    // `DOTS_SANDBOX_REQUIRE_RUNTIME=1` suppresses the degradation below and
    // forces every tier to attempt its real launch regardless of what the
    // match below would otherwise say, following the same injection
    // convention as `$DOTS_SANDBOX_DEFAULTS` and friends. It can only ever
    // make confinement stricter — forcing an attempt that then fails loudly
    // — so unlike `DOTS_SANDBOX=0` in the wrapper scripts, it is not a route
    // to less isolation. This is what lets the audit tests exercise the
    // sandboxed path on a host whose nsresourced is not enabled.
    if env::var_os("DOTS_SANDBOX_REQUIRE_RUNTIME").is_some_and(|value| value == "1") {
        return None;
    }
    match tier {
        // bubblewrap needs nothing but an unprivileged user namespace,
        // which this kernel allows. It deliberately does NOT consult
        // nsresourced: that daemon is only involved in the systemd spawn
        // tiers, and checking it here was actively wrong — it made bwrap
        // launches degrade on a condition bwrap does not care about.
        policy::Tier::Bwrap => None,
        policy::Tier::Container | policy::Tier::Vm => {
            if !Path::new(NSRESOURCED_SOCKET).exists() {
                return Some(format!(
                    "{NSRESOURCED_SOCKET} is absent, so systemd-nsresourced is not \
                     running and the {tier} tier cannot claim a UID range"
                ));
            }
            // Present is not the same as usable. nsresourced delegates a
            // namespace by installing a BPF LSM program, and a systemd
            // built without BPF runs the daemon, answers Varlink, and
            // cannot delegate — so every readiness check passes while the
            // tier is dead. See tests/live_grant.rs for the measurements.
            None
        }
    }
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
            // Degrade rather than refuse. A host that cannot start a
            // sandbox must still run the app: refusing outright would mean
            // every `nix run .#<app>` (or wrapped binary) stops working the
            // moment this tier check trips, with no recourse short of a
            // rebuild — worse than the app running unconfined in the
            // meantime.
            //
            // The cost is real, and stating it honestly matters more than
            // stating the benefit: this fires exactly when something is
            // already wrong and nobody is reading stderr. The line below
            // plus the audit record are the ENTIRE mitigation — there is no
            // retry, no alert, nothing else that makes this loud. A machine
            // whose audit log holds `unconfined_runtime_unavailable` entries
            // needs the sandbox host module enabled and a rebuild, not a
            // shrug because nothing crashed.
            if let Some(reason) = tier_unavailable(resolved.tier) {
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
    let defaults_path = env::var_os("DOTS_SANDBOX_DEFAULTS").map_or_else(
        || home_dir.join(".config/dots-sandbox/defaults.json"),
        PathBuf::from,
    );
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
/// Walk up from the working directory looking for a `flake.nix`.
///
/// Returns the first ancestor that has one, or `None` if the launcher was
/// invoked from outside any flake checkout — in which case the caller falls
/// back rather than binding a directory picked at random.
///
/// `flake.nix` rather than `.git`: the thing being bound is the flake this
/// app was launched from, and a `.git` hit could be any unrelated
/// repository the user happened to be sitting in.
fn discover_repo_root() -> Option<PathBuf> {
    let mut dir = env::current_dir().ok()?;
    loop {
        if dir.join("flake.nix").is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn build_ctx(
    app_id: &str,
    program: &str,
    args: &[String],
    home_dir: PathBuf,
) -> Result<LaunchCtx, LaunchError> {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or(LaunchError::MissingEnv("XDG_RUNTIME_DIR"))?;
    // `$DOTS_SANDBOX_REPO_ROOT` wins; otherwise the checkout is discovered
    // by walking up from the working directory for a `flake.nix`.
    //
    // The previous default was a bare `~/dots`, which is a guess about where
    // someone cloned their dotfiles, and on this machine it is wrong — the
    // checkout is under ~/Dokumente/codeberg/personal/dots. Every launch of
    // a repo-touching app died on `Failed to parse --bind= argument
    // /home/matus/dots: No such file or directory`, which is a confusing
    // way to say "I looked in the wrong place". Discovery makes `nix run
    // .#<app>` work from anywhere inside the checkout, which is where it is
    // always run from; `~/dots` survives only as the last resort so the
    // behaviour is never worse than it was.
    let repo_root = env::var_os("DOTS_SANDBOX_REPO_ROOT")
        .map(PathBuf::from)
        .or_else(discover_repo_root)
        .unwrap_or_else(|| home_dir.join("dots"));
    // Empty when there is no compositor — a TTY login, a CI runner. The
    // wayland bind is --ro-bind-try, so an absent socket is not fatal.
    let wayland_display = env::var("WAYLAND_DISPLAY").unwrap_or_default();
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
        wayland_display,
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
