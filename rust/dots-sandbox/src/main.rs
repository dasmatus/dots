//! Provisional scaffold: wires up only the four subcommands task 9 owns
//! (`run`, `grant`, `revoke`, `list`). The policy half's own subcommands
//! (and whatever argument-parsing front end it picks) do not exist in
//! this worktree — reconcile this dispatch with theirs at merge time
//! rather than trusting it as the final `main.rs`. Parsing is hand-rolled
//! rather than pulled in via a CLI-framework dependency, matching the
//! rest of this repo's Rust (see `rust/settings-global/src/main.rs`) and
//! keeping this scaffold's own dependency footprint out of the way of
//! whatever the policy half already chose.
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

use dots_sandbox::broker::{AuditLog, Interactivity};
use dots_sandbox::grants::{self, GrantKind};
use dots_sandbox::launch;

const USAGE: &str = "usage: dots-sandbox <run|grant|revoke|list> [OPTIONS...]

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
      List running sandbox machines (`machinectl --user list`).";

fn main() -> ExitCode {
    tracing_subscriber::fmt().without_time().init();

    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    };
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "run" => run_command(&rest),
        "grant" => grant_command(&rest),
        "revoke" => revoke_command(&rest),
        "list" => list_command(),
        other => {
            eprintln!("dots-sandbox: unknown command {other:?}\n\n{USAGE}");
            ExitCode::FAILURE
        }
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

fn exit_code_from_i32(code: i32) -> ExitCode {
    // `ExitCode` only exposes 0..=255 in stable Rust (`ExitCode::from`
    // takes a `u8`); clamp rather than panic on a signal-derived code
    // above that range, which `launch::run`'s 128+signal convention can
    // legitimately produce.
    ExitCode::from(u8::try_from(code.clamp(0, 255)).unwrap_or(255))
}
