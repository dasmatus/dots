//! Headless frontends over the settings store: `dump`/`set` for scripting and
//! `serve` for beamenu-canvas's JSON-RPC form view. Only the file
//! replacement is privileged, done by re-running this binary's `write` mode
//! under pkexec with the rendered file on stdin — unchanged from the retired
//! rofi frontend.

use std::env;
use std::io::{self, BufRead as _, Read as _, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use global_settings::menu::{apply_values, dump, Action, ITEMS};
use global_settings::rpc::{self, Incoming};
use global_settings::settings::Settings;

const DEFAULT_FILE: &str = "/var/lib/dots/settings.nix";

const USAGE: &str = "usage: global-settings <dump|set|serve|write> [--file PATH]

  dump              print every field as a JSON array (for scripting)
  set <key> <value> validate and write one field
  serve             speak JSON-RPC 2.0 over stdio (for beamenu-canvas)
  write             replace PATH with a validated settings.nix read from
                    stdin (serve/set re-exec this mode under pkexec when
                    PATH is root-owned)

PATH defaults to /var/lib/dots/settings.nix.";

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let Some(mode) = args.next() else {
        eprintln!("{USAGE}");
        return ExitCode::FAILURE;
    };
    match mode.as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "dump" => match parse_args(args) {
            Ok((file, _)) => dump_mode(&file),
            Err(e) => usage_failure(&e),
        },
        "set" => match parse_args(args) {
            Ok((file, positionals)) => match <[String; 2]>::try_from(positionals) {
                Ok([key, value]) => set_mode(&file, &key, &value),
                Err(got) => usage_failure(&format!(
                    "`set` needs <key> <value>, got {} args",
                    got.len()
                )),
            },
            Err(e) => usage_failure(&e),
        },
        "serve" => match parse_args(args) {
            Ok((file, _)) => serve_mode(&file),
            Err(e) => usage_failure(&e),
        },
        "write" => match parse_args(args) {
            Ok((file, _)) => write_from_stdin(&file),
            Err(e) => usage_failure(&e),
        },
        other => usage_failure(&format!("unknown argument `{other}`")),
    }
}

fn usage_failure(message: &str) -> ExitCode {
    eprintln!("{message}\n{USAGE}");
    ExitCode::FAILURE
}

/// Split a mode's remaining args into `--file PATH` (default
/// `DEFAULT_FILE`) and everything else, in order.
fn parse_args(args: impl Iterator<Item = String>) -> Result<(PathBuf, Vec<String>), String> {
    let mut file = PathBuf::from(DEFAULT_FILE);
    let mut positionals = Vec::new();
    let mut args = args;
    while let Some(arg) = args.next() {
        if arg == "--file" {
            file = PathBuf::from(args.next().ok_or("--file needs a path")?);
        } else {
            positionals.push(arg);
        }
    }
    Ok((file, positionals))
}

/// `dump`: print every item's current value as a JSON array.
fn dump_mode(file: &Path) -> ExitCode {
    let settings = match Settings::load(file) {
        Ok(settings) => settings,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match serde_json::to_string(&dump(&settings)) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("cannot encode settings: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `set <key> <value>`: validate (for `EditStr` keys) or parse `true`/`false`
/// (for `Toggle` keys), then save through the same path as the JSON-RPC form.
fn set_mode(file: &Path, key: &str, value: &str) -> ExitCode {
    let Some(item) = ITEMS.iter().find(|item| item.key() == key) else {
        eprintln!("unknown key `{key}`");
        return ExitCode::FAILURE;
    };
    let mut settings = match Settings::load(file) {
        Ok(settings) => settings,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match &item.action {
        Action::EditStr { validate, .. } => {
            if let Err(e) = validate(value) {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
            settings.set_str(key, value);
        }
        Action::Toggle { .. } => match value {
            "true" => settings.set_bool(key, true),
            "false" => settings.set_bool(key, false),
            other => {
                eprintln!("`{key}` is a checkbox; expected `true` or `false`, got `{other}`");
                return ExitCode::FAILURE;
            }
        },
    }
    match save(&settings, file) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// `serve`: render the form once, then loop handling `form.submit` requests
/// and the `shutdown` notification over stdio.
fn serve_mode(file: &Path) -> ExitCode {
    let mut settings = match Settings::load(file) {
        Ok(settings) => settings,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let mut stdout = io::stdout();
    if send_line(&mut stdout, &rpc::render_notification(&settings)).is_err() {
        return ExitCode::FAILURE;
    }

    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        match rpc::parse_line(&line) {
            Ok(Incoming::Shutdown) => return ExitCode::SUCCESS,
            Ok(Incoming::FormSubmit { id, values }) => {
                let mut trial = settings.clone();
                let outcome = apply_values(&mut trial, &values).and_then(|changed| {
                    if changed {
                        save(&trial, file)?;
                    }
                    Ok(changed)
                });
                match outcome {
                    Ok(changed) => {
                        if send_line(&mut stdout, &rpc::result_response(&id)).is_err() {
                            break;
                        }
                        if changed {
                            settings = trial;
                            if send_line(&mut stdout, &rpc::render_notification(&settings)).is_err()
                            {
                                break;
                            }
                        }
                    }
                    Err(message) => {
                        if send_line(&mut stdout, &rpc::error_response(&id, &message)).is_err() {
                            break;
                        }
                    }
                }
            }
            Ok(Incoming::Unknown {
                id: Some(id),
                method,
            }) => {
                let message = format!("unknown method `{method}`");
                if send_line(&mut stdout, &rpc::error_response(&id, &message)).is_err() {
                    break;
                }
            }
            Ok(Incoming::Unknown { id: None, .. }) => {
                // An unrecognised notification: nothing to respond to, and
                // nothing this worker knows how to act on.
            }
            Err(e) => eprintln!("{e}"),
        }
    }
    ExitCode::SUCCESS
}

fn send_line(out: &mut impl Write, line: &str) -> io::Result<()> {
    writeln!(out, "{line}")?;
    out.flush()
}

/// The pkexec-elevated half: stdin holds the whole new settings.nix; refuse
/// anything that does not parse, then atomically replace `file`.
fn write_from_stdin(file: &Path) -> ExitCode {
    let mut src = String::new();
    if let Err(e) = io::stdin().read_to_string(&mut src) {
        eprintln!("cannot read stdin: {e}");
        return ExitCode::FAILURE;
    }
    let parsed = match Settings::parse(&src) {
        Ok(parsed) => parsed,
        Err(e) => {
            eprintln!("refusing to write: {e}");
            return ExitCode::FAILURE;
        }
    };
    match parsed.save(file) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Direct save when the file is user-writable; otherwise re-exec ourselves
/// as `write` under pkexec and pipe the rendered file in.
fn save(settings: &Settings, file: &Path) -> Result<(), String> {
    if settings.save(file).is_ok() {
        return Ok(());
    }
    let exe = env::current_exe().map_err(|e| format!("cannot find own binary: {e}"))?;
    let mut child = Command::new("pkexec")
        .arg(exe)
        .arg("write")
        .arg("--file")
        .arg(file)
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run pkexec: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("pkexec stdin unavailable")?
        .write_all(settings.render().as_bytes())
        .map_err(|e| format!("cannot pipe settings to pkexec: {e}"))?;
    let status = child
        .wait()
        .map_err(|e| format!("pkexec did not finish: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("privileged write failed (pkexec dismissed?)".into())
    }
}
