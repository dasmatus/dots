//! `dots-sandbox`: policy resolution, launch and live grants for the
//! per-app sandbox, in one CLI.
//!
//! `policy validate`/`policy dump` check and print the policy model
//! itself (for the Nix flake check and the QML Settings page, the same
//! way it already consumes `global-settings dump`); `run` launches an app
//! sandboxed and forwards signals to it; `grant`/`revoke`/`list` manage
//! live binds against an already-running sandbox machine via
//! `machinectl --user`. Argument parsing is hand-rolled throughout,
//! matching `rust/settings-global` and the rest of this repo's Rust: no
//! CLI-framework dependency here.
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use dots_sandbox::broker::{AuditLog, Interactivity};
use dots_sandbox::catalog;
use dots_sandbox::daemon;
use dots_sandbox::error::PolicyError;
use dots_sandbox::grants::{self, GrantKind};
use dots_sandbox::launch;
use dots_sandbox::policy::{self, PolicyFile, ResolvedPolicySet};
use dots_sandbox::report;

const USAGE: &str =
    "usage: dots-sandbox <policy validate|policy dump|run|grant|revoke|list|catalog> \
[OPTIONS...]

  policy validate [PATH]   parse and check a policy file under defaults
                           semantics; PATH defaults to
                           $DOTS_SANDBOX_DEFAULTS, falling back to
                           ~/.config/dots-sandbox/defaults.json
  policy dump [--app ID]   print the merged, resolved policy as JSON for
                           one app, or for every app the defaults catalog
                           defines if --app is omitted; defaults are read
                           the same way as `validate`, overrides come from
                           ~/.config/dots-sandbox/overrides.json (missing
                           is not an error: it is the normal state for a
                           user who has never touched the sandbox
                           settings)

  run --app ID [--interactive] -- PROGRAM [ARGS...]
      Resolve ID's policy, launch PROGRAM sandboxed, forward signals to
      it, and exit with its exit code. Without --interactive the app is
      treated as a wrapped CLI app: an `ask` capability is denied rather
      than ever prompting.

  grant --machine NAME --path HOST[:SANDBOX] [--read-only] [--mkdir]
  grant --machine NAME --volume PROVIDER:VOLUME[:CONFIG][:K=V,...]
      Bind a path or volume into a running machine via `machinectl --user`.

  revoke --machine NAME --volume PROVIDER:VOLUME
      Detach a volume previously attached with `grant --volume`. Plain
      path grants have no live revoke; restart the sandbox instead.

  list
      List running sandbox machines (`machinectl --user list`).

  report --json
      Print the privacy/hardware-security dashboard as one JSON document:
      what recently touched a sensor, and how hard this machine is to
      attack. Read-only and unprivileged throughout; every external
      command it consults is optional, and a missing one degrades only
      its own card.

  catalog [--json]
      Print the Settings permissions-page catalog as one JSON document:
      one entry per app carrying X-Dots-Sandbox-AppId in a desktop file
      under $XDG_DATA_HOME/applications or $XDG_DATA_DIRS/applications
      (first directory wins), each merged with its currently resolved
      policy. An app the defaults catalog defines but no desktop file
      names still appears, with a null source.";

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .without_time()
        .with_writer(std::io::stderr)
        .init();

    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        return usage_failure("no arguments given");
    };
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "policy" => policy_command(&rest),
        "run" => run_command(&rest),
        "grant" => grant_command(&rest),
        "revoke" => revoke_command(&rest),
        "list" => list_command(),
        "report" => report_command(&rest),
        "catalog" => catalog_command(&rest),
        "daemon" => daemon_command(&rest),
        other => usage_failure(&format!("unknown command {other:?}")),
    }
}

/// `dots-sandbox daemon` — claim `org.dots.Sandbox1` on the session bus and
/// serve until stopped.
///
/// Blocks forever by design: it is a systemd `Type=dbus` service, and
/// systemd owns its lifetime. It takes no arguments beyond the policy path
/// overrides every other subcommand already honours, so a broken policy
/// fails at startup where systemd will report it, rather than on the first
/// method call where a UI would have to explain it.
fn daemon_command(args: &[String]) -> ExitCode {
    if !args.is_empty() {
        return usage_failure("dots-sandbox daemon: takes no arguments");
    }

    let Ok(home) = env::var("HOME") else {
        eprintln!("dots-sandbox daemon: cannot resolve the policy paths: $HOME is not set");
        return ExitCode::FAILURE;
    };
    let home = PathBuf::from(home);

    let defaults = match defaults_path(None) {
        Ok(path) => path,
        Err(message) => {
            eprintln!("dots-sandbox daemon: {message}");
            return ExitCode::FAILURE;
        }
    };

    let sandbox = match daemon::Sandbox::new(home.clone(), defaults, overrides_path(&home)) {
        Ok(sandbox) => sandbox,
        Err(err) => return report_and_fail(err),
    };

    // zbus 5 runs on async-io/smol rather than tokio, so this is the whole
    // runtime: one blocking call that drives the connection for the life of
    // the process. Deliberately not a tokio runtime — nothing else in this
    // repo needs one, and the launch path must stay free of it.
    zbus::block_on(async {
        match daemon::serve(sandbox).await {
            Ok(_connection) => {
                tracing::info!(bus = daemon::BUS_NAME, "serving");
                // Park. Dropping the connection would release the name.
                std::future::pending::<()>().await;
                ExitCode::SUCCESS
            }
            Err(err) => {
                eprintln!("dots-sandbox daemon: {err}");
                ExitCode::FAILURE
            }
        }
    })
}

fn usage_failure(message: &str) -> ExitCode {
    eprintln!("{message}\n{USAGE}");
    ExitCode::FAILURE
}

/// Prints a policy error as a full `miette` diagnostic report (code, help
/// text and all) and returns the failure exit code the caller hands back
/// from `main`.
fn report_and_fail(error: PolicyError) -> ExitCode {
    eprintln!("{:?}", miette::Report::new(error));
    ExitCode::FAILURE
}

fn policy_command(args: &[String]) -> ExitCode {
    match args.split_first() {
        Some((sub, rest)) => match sub.as_str() {
            "validate" => validate_mode(rest.first().map(PathBuf::from)),
            "dump" => dump_mode(parse_dump_args(rest)),
            other => usage_failure(&format!("unknown `policy` subcommand {other:?}")),
        },
        None => usage_failure("`policy` needs a subcommand: `validate` or `dump`"),
    }
}

/// Pulls `--app ID` out of `policy dump`'s remaining arguments, if given.
fn parse_dump_args(args: &[String]) -> Option<String> {
    args.iter()
        .position(|arg| arg == "--app")
        .and_then(|i| args.get(i + 1))
        .cloned()
}

/// Resolves the defaults file path: an explicit `PATH` argument first,
/// then `$DOTS_SANDBOX_DEFAULTS` (how the flake wrapper points at a store
/// path), then `~/.config/dots-sandbox/defaults.json`.
fn defaults_path(explicit: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Ok(path) = env::var("DOTS_SANDBOX_DEFAULTS") {
        return Ok(PathBuf::from(path));
    }
    let home = env::var("HOME")
        .map_err(|_| "cannot resolve the default defaults path: $HOME is not set".to_string())?;
    Ok(Path::new(&home).join(".config/dots-sandbox/defaults.json"))
}

/// The fixed, per-user overrides path: never a store path, always a plain
/// user file (see the crate brief on why: these are per-user preferences,
/// not machine identity, and are never written through `pkexec`).
fn overrides_path(home: &Path) -> PathBuf {
    home.join(".config/dots-sandbox/overrides.json")
}

fn read_policy_file(path: &Path) -> Result<PolicyFile, PolicyError> {
    let contents = fs::read_to_string(path).map_err(|source| PolicyError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    policy::parse_policy_file(path, &contents)
}

fn validate_mode(explicit: Option<PathBuf>) -> ExitCode {
    let path = match defaults_path(explicit) {
        Ok(path) => path,
        Err(message) => return usage_failure(&message),
    };
    let file = match read_policy_file(&path) {
        Ok(file) => file,
        Err(e) => return report_and_fail(e),
    };
    match policy::validate_strict(&file) {
        Ok(()) => {
            println!("{} is valid", path.display());
            ExitCode::SUCCESS
        }
        Err(e) => report_and_fail(e),
    }
}

fn dump_mode(app_filter: Option<String>) -> ExitCode {
    let defaults_path = match defaults_path(None) {
        Ok(path) => path,
        Err(message) => return usage_failure(&message),
    };
    let home = match env::var("HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => return usage_failure("cannot resolve overrides or expand `~`: $HOME is not set"),
    };
    let defaults = match read_policy_file(&defaults_path) {
        Ok(file) => file,
        Err(e) => return report_and_fail(e),
    };
    let overrides_path = overrides_path(&home);
    let overrides = if overrides_path.exists() {
        match read_policy_file(&overrides_path) {
            Ok(file) => file,
            Err(e) => return report_and_fail(e),
        }
    } else {
        policy::empty_overrides(defaults.version)
    };

    let json = match app_filter {
        Some(app_id) => {
            policy::resolve_app(&defaults, &overrides, &app_id, &home).and_then(|resolved| {
                serde_json::to_string(&resolved).map_err(|source| PolicyError::Serialize { source })
            })
        }
        None => policy::resolve_all(&defaults, &overrides, &home).and_then(|set| {
            serde_json::to_string(&set).map_err(|source| PolicyError::Serialize { source })
        }),
    };
    match json {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(e) => report_and_fail(e),
    }
}

fn run_command(args: &[String]) -> ExitCode {
    let mut app_id = None;
    let mut interactive = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--app" => {
                i += 1;
                app_id = args.get(i).cloned();
            }
            "--interactive" => interactive = true,
            "--" => {
                i += 1;
                break;
            }
            other => {
                eprintln!("dots-sandbox run: unexpected argument {other:?}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }
    let Some(app_id) = app_id else {
        eprintln!("dots-sandbox run: --app ID is required");
        return ExitCode::FAILURE;
    };
    let Some((program, program_args)) = args[i..].split_first() else {
        eprintln!("dots-sandbox run: no program given after `--`");
        return ExitCode::FAILURE;
    };

    let audit = AuditLog::open_default();
    let interactivity = if interactive {
        Interactivity::Interactive
    } else {
        Interactivity::NonInteractive
    };
    match launch::run(&app_id, program, program_args, interactivity, &audit) {
        Ok(outcome) => exit_code_from_i32(outcome.exit_code),
        Err(err) => {
            eprintln!("dots-sandbox run: {:?}", miette::Report::new(err));
            ExitCode::FAILURE
        }
    }
}

fn grant_command(args: &[String]) -> ExitCode {
    let mut machine = None;
    let mut path = None;
    let mut volume = None;
    let mut read_only = false;
    let mut mkdir = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--machine" => {
                i += 1;
                machine = args.get(i).cloned();
            }
            "--path" => {
                i += 1;
                path = args.get(i).cloned();
            }
            "--volume" => {
                i += 1;
                volume = args.get(i).cloned();
            }
            "--read-only" => read_only = true,
            "--mkdir" => mkdir = true,
            other => {
                eprintln!("dots-sandbox grant: unexpected argument {other:?}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }
    let Some(machine) = machine else {
        eprintln!("dots-sandbox grant: --machine NAME is required");
        return ExitCode::FAILURE;
    };

    let kind = match (path, volume) {
        (Some(path_spec), None) => {
            let (host, sandbox) = match path_spec.split_once(':') {
                Some((h, s)) => (PathBuf::from(h), Some(PathBuf::from(s))),
                None => (PathBuf::from(&path_spec), None),
            };
            GrantKind::Path {
                host_path: host,
                sandbox_path: sandbox,
                read_only,
                mkdir,
            }
        }
        (None, Some(spec)) => GrantKind::Volume { spec },
        (None, None) => {
            eprintln!("dots-sandbox grant: one of --path or --volume is required");
            return ExitCode::FAILURE;
        }
        (Some(_), Some(_)) => {
            eprintln!("dots-sandbox grant: --path and --volume are mutually exclusive");
            return ExitCode::FAILURE;
        }
    };

    let audit = AuditLog::open_default();
    // "grant" run from the CLI is an already-decided operator action, so
    // it is logged under the app id "cli" rather than attributed to a
    // sandboxed app that never asked for it itself.
    match grants::grant(&audit, "cli", &machine, &kind) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("dots-sandbox grant: {:?}", miette::Report::new(err));
            ExitCode::FAILURE
        }
    }
}

fn revoke_command(args: &[String]) -> ExitCode {
    let mut machine = None;
    let mut volume = None;
    let mut path = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--machine" => {
                i += 1;
                machine = args.get(i).cloned();
            }
            "--volume" => {
                i += 1;
                volume = args.get(i).cloned();
            }
            "--path" => {
                i += 1;
                path = args.get(i).cloned();
            }
            other => {
                eprintln!("dots-sandbox revoke: unexpected argument {other:?}");
                return ExitCode::FAILURE;
            }
        }
        i += 1;
    }
    let Some(machine) = machine else {
        eprintln!("dots-sandbox revoke: --machine NAME is required");
        return ExitCode::FAILURE;
    };

    if path.is_some() {
        eprintln!(
            "dots-sandbox revoke: {:?}",
            miette::Report::new(grants::revoke_path_grant_unsupported())
        );
        return ExitCode::FAILURE;
    }
    let Some(volume) = volume else {
        eprintln!("dots-sandbox revoke: --volume PROVIDER:VOLUME is required");
        return ExitCode::FAILURE;
    };

    let audit = AuditLog::open_default();
    match grants::revoke(&audit, "cli", &machine, &volume) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("dots-sandbox revoke: {:?}", miette::Report::new(err));
            ExitCode::FAILURE
        }
    }
}

fn list_command() -> ExitCode {
    match grants::list_machines() {
        Ok(machines) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&machines).unwrap_or_default()
            );
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("dots-sandbox list: {:?}", miette::Report::new(err));
            ExitCode::FAILURE
        }
    }
}

fn report_command(args: &[String]) -> ExitCode {
    // `--json` is the only output this subcommand knows how to produce
    // today; naming it explicitly (rather than accepting any bare
    // `report`) leaves room for a future human-readable mode without an
    // ambiguous default to change later.
    if args != ["--json"] {
        return usage_failure("dots-sandbox report: only `--json` is supported");
    }
    match serde_json::to_string(&report::collect()) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("dots-sandbox report: failed to serialize the report: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Loads defaults + overrides exactly the way `policy dump` does and
/// resolves every app the defaults catalog defines in one pass — the
/// input `catalog` needs to pair against a desktop-file scan. Every
/// error path has already printed its own diagnostic by the time this
/// returns `Err`, so the caller only needs to propagate the exit code.
fn resolve_full_policy(home: &Path) -> Result<ResolvedPolicySet, ExitCode> {
    let defaults_path = defaults_path(None).map_err(|message| usage_failure(&message))?;
    let defaults = read_policy_file(&defaults_path).map_err(report_and_fail)?;
    let overrides_path = overrides_path(home);
    let overrides = if overrides_path.exists() {
        read_policy_file(&overrides_path).map_err(report_and_fail)?
    } else {
        policy::empty_overrides(defaults.version)
    };
    policy::resolve_all(&defaults, &overrides, home).map_err(report_and_fail)
}

fn catalog_command(args: &[String]) -> ExitCode {
    // `--json` is optional and changes nothing today, mirroring `report`:
    // it names the one output shape this subcommand knows, leaving room
    // for a future human-readable mode without an ambiguous default to
    // change later.
    if !(args.is_empty() || args == ["--json"]) {
        return usage_failure("dots-sandbox catalog: only an optional `--json` is supported");
    }
    let home = match env::var("HOME") {
        Ok(home) => PathBuf::from(home),
        Err(_) => {
            return usage_failure("cannot resolve the XDG applications scan: $HOME is not set")
        }
    };
    let resolved = match resolve_full_policy(&home) {
        Ok(resolved) => resolved,
        Err(code) => return code,
    };
    let catalog = catalog::scan(&home, &resolved);
    match serde_json::to_string(&catalog) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("dots-sandbox catalog: failed to serialize the catalog: {err}");
            ExitCode::FAILURE
        }
    }
}

fn exit_code_from_i32(code: i32) -> ExitCode {
    // `ExitCode` only exposes 0..=255 in stable Rust (`ExitCode::from`
    // takes a `u8`); clamp rather than panic on a signal-derived code
    // above that range, which `launch::run`'s 128+signal convention can
    // legitimately produce.
    ExitCode::from(u8::try_from(code.clamp(0, 255)).unwrap_or(255))
}
