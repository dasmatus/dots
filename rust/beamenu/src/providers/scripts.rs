//! Script commands, Raycast's extension mechanism.
//!
//! Any executable in `$XDG_CONFIG_HOME/beamenu/scripts` becomes a command if
//! it carries a metadata header in comments, the same convention Raycast's
//! script commands use:
//!
//! ```text
//! #!/usr/bin/env bash
//! # @beamenu.title Restart Waybar
//! # @beamenu.subtitle Kill and respawn the bar
//! # @beamenu.icon /path/to/icon.svg
//! ```
//!
//! A file without a title is skipped rather than shown under its filename:
//! an un-annotated script in that directory is far more likely to be a helper
//! another script sources than something meant for the launcher.

use std::path::{Path, PathBuf};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

pub struct Scripts;

/// Prefix marking a metadata line.
const MARKER: &str = "@beamenu.";

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Metadata {
    pub title: Option<String>,
    pub subtitle: Option<String>,
    pub icon: Option<String>,
}

/// Extract the metadata header from a script's source.
///
/// Only the leading comment block is read: scanning the whole file would let
/// a string literal deep in a script masquerade as metadata. The scan stops
/// at the first line that is neither blank, a comment, nor a shebang.
#[must_use]
pub fn parse_metadata(source: &str) -> Metadata {
    let mut meta = Metadata::default();

    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with("#!") {
            continue;
        }
        if !trimmed.starts_with('#') && !trimmed.starts_with("//") {
            break;
        }

        let Some(start) = trimmed.find(MARKER) else {
            continue;
        };
        let rest = &trimmed[start + MARKER.len()..];
        let Some((key, value)) = rest.split_once(char::is_whitespace) else {
            continue;
        };
        let value = value.trim().to_string();
        match key {
            "title" => meta.title = Some(value),
            "subtitle" => meta.subtitle = Some(value),
            "icon" => meta.icon = Some(value),
            _ => {}
        }
    }

    meta
}

/// Executable files directly inside `dir`.
#[must_use]
pub fn executables(dir: &Path) -> Vec<PathBuf> {
    use std::os::unix::fs::PermissionsExt;

    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };

    let mut found: Vec<PathBuf> = read
        .flatten()
        .map(|e| e.path())
        .filter(|path| {
            path.is_file()
                && std::fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
        })
        .collect();
    found.sort();
    found
}

impl Provider for Scripts {
    fn id(&self) -> &'static str {
        "scripts"
    }

    fn section(&self) -> &'static str {
        "Script Commands"
    }

    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        let dir = ctx.config_dir.join("scripts");
        executables(&dir)
            .into_iter()
            .filter_map(|path| {
                let source = std::fs::read_to_string(&path).unwrap_or_default();
                let meta = parse_metadata(&source);
                let title = meta.title?;
                let quoted = format!("'{}'", path.display().to_string().replace('\'', r"'\''"));
                let mut item = Item::new(
                    format!("script:{}", path.display()),
                    title,
                    Action::Shell(quoted.clone()),
                )
                .icon(meta.icon.map(PathBuf::from))
                .alt(
                    "Run in terminal",
                    Action::Launch {
                        exec: quoted,
                        terminal: true,
                    },
                );
                if let Some(subtitle) = meta.subtitle {
                    item = item.subtitle(subtitle);
                }
                Some(item)
            })
            .collect()
    }
}
