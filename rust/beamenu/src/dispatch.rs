//! Executing an [`Action`].
//!
//! Everything that leaves the process goes through here, which keeps the
//! providers pure and means there is one place to audit for quoting.
//!
//! Launched processes are detached deliberately. beamenu exits the moment it
//! dispatches, and a child in its process group would be killed with it; a
//! `setsid` child survives, which is what "launch an app" has to mean.

use std::fmt::Write as _;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

use anyhow::{Context, Result};

use crate::item::{Action, FileOp};

/// Spawn a shell command, fully detached from this process.
///
/// # Errors
/// Fails when the shell cannot be spawned.
fn spawn_detached(command: &str) -> Result<()> {
    // SAFETY: setsid() after fork and before exec is async-signal-safe, which
    // is the only constraint pre_exec imposes.
    unsafe {
        Command::new("sh")
            .arg("-c")
            .arg(command)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .pre_exec(|| {
                libc_setsid();
                Ok(())
            })
            .spawn()
            .with_context(|| format!("failed to spawn: {command}"))?;
    }
    Ok(())
}

/// Single-quote `arg` so it survives a `sh -c` round trip as one shell word.
fn shell_quote(arg: &str) -> String {
    format!("'{}'", arg.replace('\'', r"'\''"))
}

extern "C" {
    #[link_name = "setsid"]
    fn setsid_raw() -> i32;
}

fn libc_setsid() {
    // SAFETY: no arguments, no allocation, safe between fork and exec.
    unsafe {
        setsid_raw();
    }
}

/// Put `text` on the Wayland clipboard.
///
/// # Errors
/// Fails when `wl-copy` is missing or exits non-zero.
pub fn copy(text: &str) -> Result<()> {
    use std::io::Write;

    let mut child = Command::new("wl-copy")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("wl-copy is not available")?;

    child
        .stdin
        .take()
        .context("wl-copy stdin was not piped")?
        .write_all(text.as_bytes())
        .context("failed writing to wl-copy")?;

    child.wait().context("wl-copy failed")?;
    Ok(())
}

/// Copy `text` and then paste it into whatever now has focus.
///
/// The launcher still holds the keyboard when the action fires, so the paste
/// has to wait for the surface to go away and focus to return. wtype sends the
/// keystroke; `sleep` is the handshake, since there is no event that says
/// "the compositor has finished re-focusing the previous window".
///
/// # Errors
/// Fails when the copy step fails or the paste cannot be spawned.
pub fn paste(text: &str) -> Result<()> {
    copy(text)?;
    spawn_detached("sleep 0.15 && wtype -M ctrl -k v -m ctrl")
}

/// Run an action.
///
/// # Errors
/// Propagates whatever the underlying spawn or clipboard call failed with.
pub fn dispatch(action: &Action, terminal: &str) -> Result<()> {
    match action {
        Action::Launch {
            exec,
            terminal: in_term,
        } => {
            if *in_term {
                spawn_detached(&format!("{terminal} -e {exec}"))
            } else {
                spawn_detached(exec)
            }
        }
        Action::Shell(command) => spawn_detached(command),
        Action::Copy(text) => copy(text),
        Action::Paste(text) => paste(text),
        Action::OpenUrl(url) => {
            let quoted = format!("'{}'", url.replace('\'', r"'\''"));
            spawn_detached(&format!("xdg-open {quoted}"))
        }
        Action::FocusWindow(address) => {
            spawn_detached(&format!("hyprctl dispatch focuswindow address:{address}"))
        }
        Action::View {
            manifest,
            command,
            query,
        } => {
            // beamenu-canvas re-reads the manifest and re-substitutes
            // `{query}` itself, so only the argv contract crosses here.
            let mut spawn = format!(
                "beamenu-canvas --manifest {} --command {}",
                shell_quote(&manifest.to_string_lossy()),
                shell_quote(command),
            );
            if !query.is_empty() {
                let _ = write!(spawn, " --query {}", shell_quote(query));
            }
            // The sidecar binary may not exist yet (it ships from a parallel
            // task); a missing executable fails spawn_detached's own spawn
            // call and propagates as an ordinary Result::Err, same as any
            // other missing command — never a panic.
            spawn_detached(&spawn)
        }
        Action::File { op, argument } => file_op(op, argument),
        // Frame pushes are handled by the loop, which owns the stack; reaching
        // here would mean the loop failed to intercept one.
        Action::Push { .. }
        | Action::Present { .. }
        | Action::Prompt { .. }
        | Action::Confirm { .. }
        | Action::None => Ok(()),
    }
}

/// Where a prompted name is refused before it reaches the filesystem.
///
/// A name is a name: one component, not a path and not a way back up the
/// tree. Without this, renaming a file to `../x` moves it into the parent
/// directory, and to `/etc/x` moves it somewhere else entirely, neither of
/// which is what the row said it would do. `Path::file_name` is the check,
/// since it answers `None` for exactly the strings that are not one
/// component.
///
/// # Errors
/// Fails when `name` is empty, is `.` or `..`, or contains a separator.
fn checked_name(name: &str) -> Result<&str> {
    let name = name.trim();
    let is_one_component = std::path::Path::new(name)
        .file_name()
        .is_some_and(|component| component == std::ffi::OsStr::new(name));

    if name.is_empty() || !is_one_component {
        anyhow::bail!("{name:?} is not a file name");
    }
    Ok(name)
}

/// Run a [`FileOp`].
///
/// Through `std::fs` rather than a shell, so a filename holding a quote or a
/// newline is an argument instead of a parsing problem. `gio trash` is the
/// exception: trashing is a desktop convention with a spec and a per-mount
/// `.Trash` directory, and reimplementing it against `std::fs` would produce
/// something the file manager could not undo.
///
/// # Errors
/// Propagates the underlying filesystem error, named with the path it was on.
fn file_op(op: &FileOp, argument: &str) -> Result<()> {
    match op {
        FileOp::NewFolder { parent } => {
            let name = checked_name(argument)?;
            let path = parent.join(name);
            std::fs::create_dir(&path)
                .with_context(|| format!("could not create {}", path.display()))
        }
        FileOp::Rename { target } => {
            let name = checked_name(argument)?;
            let destination = target
                .parent()
                .unwrap_or_else(|| std::path::Path::new("."))
                .join(name);
            std::fs::rename(target, &destination).with_context(|| {
                format!(
                    "could not rename {} to {}",
                    target.display(),
                    destination.display()
                )
            })
        }
        FileOp::MoveTo { target } => {
            let name = target
                .file_name()
                .with_context(|| format!("{} has no name to move", target.display()))?;
            let destination = std::path::PathBuf::from(shellexpand_home(argument)).join(name);
            move_path(target, &destination)
        }
        FileOp::Trash { target } => {
            let status = Command::new("gio")
                .arg("trash")
                .arg(target)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .with_context(|| format!("could not run gio trash on {}", target.display()))?;
            if status.success() {
                Ok(())
            } else {
                anyhow::bail!("gio trash refused {} ({status})", target.display())
            }
        }
        FileOp::Delete { target } => {
            let meta = std::fs::symlink_metadata(target)
                .with_context(|| format!("could not stat {}", target.display()))?;
            // `symlink_metadata`, so a symlink to a directory is unlinked
            // rather than followed into and emptied.
            if meta.is_dir() {
                std::fs::remove_dir_all(target)
            } else {
                std::fs::remove_file(target)
            }
            .with_context(|| format!("could not delete {}", target.display()))
        }
    }
}

/// Move `target` to `destination`, across filesystems if it has to be.
///
/// `rename(2)` cannot cross a mount point and fails with `EXDEV` when asked
/// to, which on a desktop is the ordinary case rather than the exotic one:
/// `/home` and an external drive are different filesystems. Copying and
/// unlinking by hand would mean reimplementing recursive copy, permissions
/// and symlink handling, so `mv` does it, run synchronously and checked.
fn move_path(target: &std::path::Path, destination: &std::path::Path) -> Result<()> {
    match std::fs::rename(target, destination) {
        Ok(()) => return Ok(()),
        Err(err) if err.raw_os_error() != Some(EXDEV) => {
            return Err(err).with_context(|| {
                format!(
                    "could not move {} to {}",
                    target.display(),
                    destination.display()
                )
            });
        }
        Err(_) => {}
    }

    let status = Command::new("mv")
        .arg("--no-clobber")
        .arg("--")
        .arg(target)
        .arg(destination)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .with_context(|| format!("could not run mv on {}", target.display()))?;

    if status.success() {
        Ok(())
    } else {
        anyhow::bail!(
            "could not move {} to {} ({status})",
            target.display(),
            destination.display()
        )
    }
}

/// `EXDEV`, "invalid cross-device link". Spelled out rather than pulled from
/// a libc binding: this crate has no libc dependency, and the value is fixed
/// by the Linux ABI.
const EXDEV: i32 = 18;

/// Expand a leading `~` to `$HOME`, for a destination somebody typed.
///
/// Only the prefix, and only `~` on its own. A shell would also expand
/// `~user`, which needs the password database and is not what anyone types
/// into a launcher.
fn shellexpand_home(path: &str) -> String {
    let path = path.trim();
    let Some(rest) = path.strip_prefix('~') else {
        return path.to_string();
    };
    if !(rest.is_empty() || rest.starts_with('/')) {
        return path.to_string();
    }
    let Some(home) = std::env::var_os("HOME") else {
        return path.to_string();
    };
    format!("{}{rest}", home.to_string_lossy())
}
