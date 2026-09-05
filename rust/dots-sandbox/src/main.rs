//! `dots-sandbox`: policy validation and resolution for the per-app
//! sandbox. This binary builds no sandbox itself — see `lib.rs` — it only
//! proves the policy model is well-formed (`policy validate`, for the Nix
//! flake check) and prints what a given app's merged, resolved policy
//! looks like (`policy dump`, for the QML Settings page, the same way it
//! already consumes `global-settings dump`).

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use dots_sandbox::error::PolicyError;
use dots_sandbox::policy::{self, PolicyFile};

const USAGE: &str = "usage: dots-sandbox policy <validate|dump> [OPTIONS]

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
                           settings)";

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
    match args.next().as_deref() {
        Some("policy") => match args.next().as_deref() {
            Some("validate") => validate_mode(args.next().map(PathBuf::from)),
            Some("dump") => dump_mode(parse_dump_args(args)),
            Some(other) => usage_failure(&format!("unknown `policy` subcommand `{other}`")),
            None => usage_failure("`policy` needs a subcommand: `validate` or `dump`"),
        },
        Some("-h" | "--help") => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some(other) => usage_failure(&format!("unknown argument `{other}`")),
        None => usage_failure("no arguments given"),
    }
}

fn usage_failure(message: &str) -> ExitCode {
    eprintln!("{message}\n{USAGE}");
    ExitCode::FAILURE
}

/// Pulls `--app ID` out of `policy dump`'s remaining arguments, if given.
fn parse_dump_args(args: impl Iterator<Item = String>) -> Option<String> {
    let mut args = args;
    let mut app = None;
    while let Some(arg) = args.next() {
        if arg == "--app" {
            app = args.next();
        }
    }
    app
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

/// Prints a policy error as a full `miette` diagnostic report (code, help
/// text and all) and returns the failure exit code the caller hands back
/// from `main`.
fn report_and_fail(error: PolicyError) -> ExitCode {
    eprintln!("{:?}", miette::Report::new(error));
    ExitCode::FAILURE
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
