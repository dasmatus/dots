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

use crate::item::Action;

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
        // Frame pushes are handled by the loop, which owns the stack; reaching
        // here would mean the loop failed to intercept one.
        Action::Push { .. } | Action::Present { .. } | Action::None => Ok(()),
    }
}
