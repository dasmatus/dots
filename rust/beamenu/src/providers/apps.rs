//! Installed applications, from XDG desktop entries.
//!
//! This replaces `hyprtile-sync-apps`, which scanned the same directories and
//! rewrote pages 3 and up of a JSON config. Nothing is written here: the scan
//! runs at query time, which costs a few milliseconds and can never go stale.
//!
//! Directory precedence follows the XDG basedir spec. `$XDG_DATA_DIRS` first,
//! `$XDG_DATA_HOME` last, so a user entry overrides a system one with the same
//! id, and a user override carrying `NoDisplay=true` removes the app.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

pub struct Apps;

/// One parsed `[Desktop Entry]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopEntry {
    pub name: String,
    pub exec: String,
    pub icon: Option<String>,
    pub terminal: bool,
    pub comment: Option<String>,
}

/// Parse the `[Desktop Entry]` group of a `.desktop` file.
///
/// Returns `None` for anything that should not appear in a launcher: a
/// non-`Application` type, `NoDisplay=true`, `Hidden=true`, or a missing name
/// or exec. Keys outside the `[Desktop Entry]` group are ignored, which is
/// what keeps `[Desktop Action ...]` blocks from overwriting the main entry.
#[must_use]
pub fn parse_entry(contents: &str) -> Option<DesktopEntry> {
    let mut in_entry = false;
    let mut kind = None;
    let mut name = None;
    let mut exec = None;
    let mut icon = None;
    let mut comment = None;
    let mut terminal = false;
    let mut no_display = false;
    let mut hidden = false;

    for line in contents.lines() {
        let line = line.trim_end_matches('\r');
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        // Only the unlocalised key wins; `Name[de]` and friends are skipped
        // rather than clobbering the value we already took.
        match key {
            "Type" => kind = Some(value.to_string()),
            "Name" if name.is_none() => name = Some(value.to_string()),
            "Exec" if exec.is_none() => exec = Some(value.to_string()),
            "Icon" if icon.is_none() => icon = Some(value.to_string()),
            "Comment" if comment.is_none() => comment = Some(value.to_string()),
            "Terminal" => terminal = value == "true",
            "NoDisplay" => no_display = value == "true",
            "Hidden" => hidden = value == "true",
            _ => {}
        }
    }

    if kind.as_deref() != Some("Application") || no_display || hidden {
        return None;
    }

    Some(DesktopEntry {
        name: name?,
        exec: exec?,
        icon,
        terminal,
        comment,
    })
}

/// Strip the field codes a desktop `Exec` line may carry.
///
/// `%f`, `%u` and friends are placeholders for files the launcher would pass
/// in; beamenu launches without arguments, so they go. `%%` is a literal
/// percent and must survive, which is why it is handled before the rest.
#[must_use]
pub fn clean_exec(exec: &str) -> String {
    const SENTINEL: char = '\u{1}';
    let staged = exec.replace("%%", &SENTINEL.to_string());
    let mut out = String::with_capacity(staged.len());
    let mut chars = staged.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%'
            && matches!(
                chars.peek(),
                Some('f' | 'F' | 'u' | 'U' | 'd' | 'D' | 'n' | 'N' | 'i' | 'c' | 'k' | 'v' | 'm')
            )
        {
            chars.next();
            continue;
        }
        out.push(c);
    }
    out.replace(SENTINEL, "%").trim().to_string()
}

/// XDG data directories, lowest precedence first.
#[must_use]
pub fn data_dirs() -> Vec<PathBuf> {
    let system = std::env::var("XDG_DATA_DIRS")
        .unwrap_or_else(|_| "/usr/local/share:/usr/share".to_string());
    let mut dirs: Vec<PathBuf> = system
        .split(':')
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();
    let home = std::env::var_os("XDG_DATA_HOME").map_or_else(
        || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share"),
        PathBuf::from,
    );
    dirs.push(home);
    dirs
}

/// Scan `dirs` for desktop entries, keyed by entry id so later directories
/// override earlier ones.
#[must_use]
pub fn scan(dirs: &[PathBuf]) -> BTreeMap<String, DesktopEntry> {
    let mut found: BTreeMap<String, DesktopEntry> = BTreeMap::new();

    for dir in dirs {
        let apps = dir.join("applications");
        let Ok(read) = std::fs::read_dir(&apps) else {
            continue;
        };
        for entry in read.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                continue;
            }
            let Some(id) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let Ok(contents) = std::fs::read_to_string(&path) else {
                continue;
            };
            match parse_entry(&contents) {
                Some(parsed) => {
                    found.insert(id.to_string(), parsed);
                }
                // A higher-precedence override that hides the app removes it
                // rather than leaving the system entry visible.
                None => {
                    found.remove(id);
                }
            }
        }
    }

    found
}

/// Resolve a desktop `Icon=` value to a file on disk.
///
/// An absolute path is taken as-is. A bare name is looked for in the icon
/// themes this system actually ships, largest size first, because a launcher
/// row scales down better than up.
#[must_use]
pub fn resolve_icon(name: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    if name.starts_with('/') {
        let path = PathBuf::from(name);
        return path.is_file().then_some(path);
    }

    let stem = name
        .strip_suffix(".svg")
        .or_else(|| name.strip_suffix(".png"))
        .unwrap_or(name);

    for dir in dirs.iter().rev() {
        for theme in ["MoreWaita", "hicolor", "Adwaita"] {
            let base = dir.join("icons").join(theme);
            for size in ["scalable", "256x256", "128x128", "64x64", "48x48"] {
                for ext in ["svg", "png"] {
                    let candidate = base.join(size).join("apps").join(format!("{stem}.{ext}"));
                    if candidate.is_file() {
                        return Some(candidate);
                    }
                }
            }
        }
        for ext in ["svg", "png"] {
            let flat = dir.join("pixmaps").join(format!("{stem}.{ext}"));
            if flat.is_file() {
                return Some(flat);
            }
        }
    }

    None
}

impl Provider for Apps {
    fn id(&self) -> &'static str {
        "apps"
    }

    fn section(&self) -> &'static str {
        "Applications"
    }

    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        let dirs = data_dirs();
        scan(&dirs)
            .into_iter()
            .map(|(id, entry)| {
                let exec = clean_exec(&entry.exec);
                let icon = entry
                    .icon
                    .as_deref()
                    .and_then(|name| resolve_icon(name, &dirs));
                let mut item = Item::new(
                    format!("apps:{id}"),
                    entry.name,
                    Action::Launch {
                        exec: exec.clone(),
                        terminal: entry.terminal,
                    },
                )
                .icon(icon);
                if let Some(comment) = entry.comment {
                    item = item.subtitle(comment);
                }
                item.alt(
                    "Open in terminal",
                    Action::Shell(format!("{} -e {}", ctx.config.terminal, exec)),
                )
            })
            .collect()
    }
}
