//! The clipboard watcher.
//!
//! Wayland gives no way to poll the clipboard. A selection belongs to the
//! client that owns it, and reading it needs an active data offer, so history
//! requires something long-lived holding one. `wl-paste --watch` does exactly
//! that, and this wraps it: every new selection is appended to the log the
//! clipboard provider reads.
//!
//! Run as a systemd user service by `nix/home/beamenu.nix`.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};

use crate::providers::clipboard::{append, compact, Entry, HISTORY_LIMIT};

/// Entries appended between compactions.
const COMPACT_INTERVAL: usize = 64;

/// Longest selection stored. Anything past this is almost certainly a file
/// dump or an image encoded as text, neither of which belongs in a history
/// list that renders one line per entry.
const MAX_ENTRY_BYTES: usize = 64 * 1024;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Decide whether a captured selection is worth storing.
///
/// Blank selections are noise, and oversized ones are not history.
#[must_use]
pub fn should_store(text: &str) -> bool {
    !text.trim().is_empty() && text.len() <= MAX_ENTRY_BYTES
}

/// Watch the clipboard until the watcher dies, appending to `log`.
///
/// `wl-paste --watch` runs a command per selection. Rather than spawning a
/// shell each time, this asks it to run `cat`, which writes the selection to
/// the pipe that this process reads: one long-lived child, no per-copy fork.
/// The `\0` record separator is what keeps multi-line selections intact.
///
/// # Errors
/// Fails when `wl-paste` is missing, its pipe breaks, or the log is unwritable.
pub fn watch(log: &Path) -> Result<()> {
    let mut child = Command::new("wl-paste")
        .args(["--type", "text", "--watch", "sh", "-c", "cat; printf '\\0'"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("wl-paste is not available")?;

    let stdout = child.stdout.take().context("wl-paste stdout not piped")?;
    let mut reader = BufReader::new(stdout);
    let mut appended = 0usize;

    loop {
        let mut buffer = Vec::new();
        let read = reader
            .read_until(0, &mut buffer)
            .context("failed reading from wl-paste")?;
        if read == 0 {
            break;
        }
        if buffer.last() == Some(&0) {
            buffer.pop();
        }

        let Ok(text) = String::from_utf8(buffer) else {
            // A non-UTF-8 selection is an image or some binary payload; the
            // history list has nothing useful to show for it.
            continue;
        };
        if !should_store(&text) {
            continue;
        }

        append(
            log,
            &Entry {
                at: now_secs(),
                text,
            },
        )?;

        appended += 1;
        if appended >= COMPACT_INTERVAL {
            appended = 0;
            // The log only ever grows on append, so trim it back to the
            // window the provider actually reads.
            let _ = compact(log);
        }
    }

    let _ = child.wait();
    Ok(())
}

/// Path of the clipboard log inside `state_dir`.
#[must_use]
pub fn log_path(state_dir: &Path) -> std::path::PathBuf {
    state_dir.join("clipboard.jsonl")
}

/// Entries the provider will show. Re-exported so the service and the reader
/// cannot disagree about the window.
#[must_use]
pub const fn history_limit() -> usize {
    HISTORY_LIMIT
}
