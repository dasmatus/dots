//! rofi frontend over the settings store. The menu, value inputs and error
//! dialogs are rofi windows running as the invoking user (a root rofi could
//! not even connect to the Wayland session); only the file replacement is
//! privileged, done by re-running this binary's `write` mode under pkexec
//! with the rendered file on stdin. Std-only: rofi and pkexec are spawned
//! as subprocesses, no crates involved.

use std::env;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use global_settings::menu::{rows, theme_args, Action, ITEMS};
use global_settings::settings::Settings;

const DEFAULT_FILE: &str = "/var/lib/dots/settings.nix";

const USAGE: &str = "usage: global-settings [write] [--file PATH]

Without `write`: edit PATH (default /var/lib/dots/settings.nix) via rofi.
With `write`: replace PATH with a validated settings.nix read from stdin —
the rofi menu runs this mode under pkexec to reach the root-owned default.";

fn main() -> ExitCode {
    let mut file = PathBuf::from(DEFAULT_FILE);
    let mut write_mode = false;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "write" => write_mode = true,
            "--file" => {
                let Some(path) = args.next() else {
                    eprintln!("--file needs a path\n{USAGE}");
                    return ExitCode::FAILURE;
                };
                file = PathBuf::from(path);
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            other => {
                eprintln!("unknown argument `{other}`\n{USAGE}");
                return ExitCode::FAILURE;
            }
        }
    }
    if write_mode {
        write_from_stdin(&file)
    } else {
        rofi_ui(&file)
    }
}

/// The pkexec-elevated half: stdin holds the whole new settings.nix; refuse
/// anything that does not parse, then atomically replace `file`.
fn write_from_stdin(file: &Path) -> ExitCode {
    let mut src = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut src) {
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

/// The rofi menu loop: pick a row, edit or toggle, save after each change.
fn rofi_ui(file: &Path) -> ExitCode {
    let mut settings = match Settings::load(file) {
        Ok(settings) => settings,
        Err(e) => {
            rofi_error(&e.to_string());
            return ExitCode::FAILURE;
        }
    };
    loop {
        let Some(index) = rofi_menu(&rows(&settings)) else {
            return ExitCode::SUCCESS;
        };
        let changed = match &ITEMS[index].action {
            Action::EditStr {
                key,
                prompt,
                validate,
            } => edit_str(&mut settings, key, prompt, *validate),
            Action::Toggle { key } => {
                let value = !settings.get_bool(key).unwrap_or_default();
                settings.set_bool(key, value);
                true
            }
            Action::Exit => return ExitCode::SUCCESS,
        };
        if changed {
            if let Err(e) = save(&settings, file) {
                rofi_error(&e);
                return ExitCode::FAILURE;
            }
        }
    }
}

/// rofi input prefilled with the current value; returns whether it changed.
fn edit_str(
    settings: &mut Settings,
    key: &str,
    prompt: &str,
    validate: fn(&str) -> Result<(), String>,
) -> bool {
    let current = settings.get_str(key).unwrap_or_default();
    let Some(value) = rofi_input(prompt, &current) else {
        return false;
    };
    if value == current {
        return false;
    }
    if let Err(reason) = validate(&value) {
        rofi_error(&reason);
        return false;
    }
    settings.set_str(key, &value);
    true
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

/// Show rows as a dmenu and return the selected index (None on Esc).
/// `-no-custom` so a typed filter that matches no row is ignored rather than
/// returned as `-1` (which would parse to `None` and quit the whole tool).
fn rofi_menu(rows: &[String]) -> Option<usize> {
    let out = rofi(
        &["-dmenu", "-no-custom", "-p", "Settings", "-format", "i"],
        &rows.join("\n"),
    )?;
    out.trim().parse().ok()
}

/// Free-text rofi prompt prefilled with the current value.
fn rofi_input(prompt: &str, current: &str) -> Option<String> {
    let out = rofi(&["-dmenu", "-p", prompt, "-filter", current, "-l", "0"], "")?;
    let value = out.trim_end_matches('\n');
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// rofi message dialog; falls back to stderr when rofi is unavailable.
fn rofi_error(message: &str) {
    eprintln!("{message}");
    let _ = Command::new("rofi")
        .args(theme_args(env::var("GLOBAL_SETTINGS_ROFI_THEME").ok()))
        .args(["-e", message])
        .status();
}

/// Spawn rofi with `input` on stdin; None on Esc or when rofi cannot run.
/// `GLOBAL_SETTINGS_ROFI_THEME` (set by the Nix wrapper) picks the theme.
fn rofi(args: &[&str], input: &str) -> Option<String> {
    let mut child = Command::new("rofi")
        .args(theme_args(env::var("GLOBAL_SETTINGS_ROFI_THEME").ok()))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| eprintln!("cannot run rofi: {e}"))
        .ok()?;
    child.stdin.take()?.write_all(input.as_bytes()).ok()?;
    let output = child.wait_with_output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}
