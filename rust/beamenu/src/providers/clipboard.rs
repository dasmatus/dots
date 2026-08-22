//! Clipboard history, reached with a leading `c `.
//!
//! Wayland has no way to poll the clipboard: a selection belongs to the
//! client that owns it, and reading it requires an active data offer. So
//! history needs a watcher, `beamenu --daemon`, which runs `wl-paste --watch`
//! and appends every new selection to a newline-delimited JSON log.
//!
//! The log format is one JSON object per line rather than a single array, so
//! the daemon appends with an `O_APPEND` write and never rewrites the file.
//! A truncated final line from a crash costs one entry, not the history.

use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

pub struct Clipboard;

/// Entries kept. Older ones are dropped when the log is compacted.
pub const HISTORY_LIMIT: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// Unix seconds when the selection was captured.
    pub at: u64,
    pub text: String,
}

/// Parse the newline-delimited log, newest last.
///
/// Unparseable lines are skipped rather than failing the read: a partial line
/// from an interrupted write should cost that entry and nothing else.
#[must_use]
pub fn parse_log(contents: &str) -> Vec<Entry> {
    contents
        .lines()
        .filter_map(|line| serde_json::from_str::<Entry>(line).ok())
        .collect()
}

/// Load history newest-first, de-duplicated on text.
///
/// Copying the same string twice should move it to the top rather than
/// occupy two rows, which is why de-duplication happens after the reverse.
#[must_use]
pub fn load(path: &Path) -> Vec<Entry> {
    let contents = std::fs::read_to_string(path).unwrap_or_default();
    let mut entries = parse_log(&contents);
    entries.reverse();

    let mut seen = std::collections::HashSet::new();
    entries.retain(|entry| seen.insert(entry.text.clone()));
    entries.truncate(HISTORY_LIMIT);
    entries
}

/// Append one entry to the log, creating it if needed.
///
/// # Errors
/// Fails when the log cannot be created, opened or written.
pub fn append(path: &Path, entry: &Entry) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{}", serde_json::to_string(entry)?)?;
    Ok(())
}

/// Rewrite the log keeping only the newest [`HISTORY_LIMIT`] entries.
///
/// # Errors
/// Fails when the log cannot be rewritten.
pub fn compact(path: &Path) -> anyhow::Result<()> {
    let mut entries = load(path);
    entries.reverse();
    let mut body = String::new();
    for entry in &entries {
        if let Ok(line) = serde_json::to_string(entry) {
            body.push_str(&line);
            body.push('\n');
        }
    }
    std::fs::write(path, body)?;
    Ok(())
}

/// One-line preview of a clipboard entry.
#[must_use]
pub fn preview(text: &str) -> String {
    let single: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if single.chars().count() > 80 {
        let head: String = single.chars().take(79).collect();
        format!("{head}\u{2026}")
    } else {
        single
    }
}

/// Human-readable age, in the coarse units a history list wants.
#[must_use]
pub fn relative_age(then: u64, now: u64) -> String {
    let secs = now.saturating_sub(then);
    match secs {
        0..=59 => "just now".to_string(),
        60..=3_599 => format!("{}m ago", secs / 60),
        3600..=86_399 => format!("{}h ago", secs / 3600),
        _ => format!("{}d ago", secs / 86_400),
    }
}

impl Provider for Clipboard {
    fn id(&self) -> &'static str {
        "clipboard"
    }

    fn section(&self) -> &'static str {
        "Clipboard History"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix("c ")
    }

    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());

        load(&ctx.state_dir.join("clipboard.jsonl"))
            .into_iter()
            .enumerate()
            .map(|(index, entry)| {
                Item::new(
                    format!("clipboard:{index}"),
                    preview(&entry.text),
                    Action::Paste(entry.text.clone()),
                )
                .accessory(relative_age(entry.at, now))
                .alt("Copy", Action::Copy(entry.text))
            })
            .collect()
    }
}
