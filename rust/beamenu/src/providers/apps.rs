//! Installed applications, from XDG desktop entries.
//!
//! This replaces `hyprtile-sync-apps`, which scanned the same directories and
//! rewrote pages 3 and up of a JSON config. Nothing is written here: the scan
//! runs at query time, which costs a few milliseconds and can never go stale.
//!
//! Directory precedence follows the XDG basedir spec. `$XDG_DATA_DIRS` first,
//! `$XDG_DATA_HOME` last, so a user entry overrides a system one with the same
//! id, and a user override carrying `NoDisplay=true` removes the app.
//!
//! Each entry also carries its `[Desktop Action …]` groups, which become the
//! row's Ctrl+K alternates. That is where the launcher gets per-app
//! sub-actions for free — "New Private Window", "Writer", "Start Paused" are
//! already on disk, written by whoever packaged the app, and need no
//! per-application configuration on this side.

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
    /// The entry's `[Desktop Action …]` groups, in the order `Actions=`
    /// declared them.
    pub actions: Vec<DesktopAction>,
}

/// One `[Desktop Action …]` group: an entry the desktop offers on right-click,
/// and what beamenu offers on Ctrl+K.
///
/// The group's `Icon=` is read past rather than kept: a child row already
/// shows its parent's icon, and the action panel has no icon column at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopAction {
    /// The group id, as `Actions=` spells it — `new-private-window`, not
    /// "New Private Window".
    ///
    /// Kept alongside the display name because this is what a row's stable id
    /// is built from, and the display name is neither stable (it is localised)
    /// nor unique.
    pub id: String,
    pub name: String,
    pub exec: String,
}

/// Which group of a desktop file the parser is currently inside.
///
/// The action id borrows from the file contents rather than owning a `String`,
/// so it can key the in-progress map directly: the parser reassigns this on
/// every header, and an owned id would be borrowed by the map it was still
/// keying.
#[derive(Clone, Copy)]
enum Group<'a> {
    /// `[Desktop Entry]`, the main group.
    Main,
    /// `[Desktop Action <id>]`, carrying that id.
    Action(&'a str),
    /// Any other group, including the space before the first header.
    Other,
}

/// An action group mid-parse, before it is known whether it carried both of
/// the keys an action needs to be usable.
#[derive(Default)]
struct PartialAction {
    name: Option<String>,
    exec: Option<String>,
}

/// Parse the `[Desktop Entry]` group of a `.desktop` file.
///
/// Returns `None` for anything that should not appear in a launcher: a
/// non-`Application` type, `NoDisplay=true`, `Hidden=true`, or a missing name
/// or exec. `[Desktop Action ...]` groups are read into
/// [`DesktopEntry::actions`] rather than into the main entry, so they can
/// never overwrite it.
///
/// Only actions named by the main group's `Actions=` are kept, in that order:
/// the spec says a group nobody declared must not be shown, and the declared
/// order is the one the app chose for its own right-click menu.
#[must_use]
pub fn parse_entry(contents: &str) -> Option<DesktopEntry> {
    let mut group = Group::Other;
    let mut kind = None;
    let mut name = None;
    let mut exec = None;
    let mut icon = None;
    let mut comment = None;
    let mut terminal = false;
    let mut no_display = false;
    let mut hidden = false;
    let mut declared: Vec<&str> = Vec::new();
    let mut groups: BTreeMap<&str, PartialAction> = BTreeMap::new();

    for line in contents.lines() {
        let line = line.trim_end_matches('\r');
        if line.starts_with('[') {
            group = match line.strip_prefix("[Desktop Action ").and_then(strip_header) {
                Some(id) => Group::Action(id),
                None if line == "[Desktop Entry]" => Group::Main,
                None => Group::Other,
            };
            continue;
        }
        // Bail before splitting for groups nothing is collected from. Desktop
        // files are mostly localisation, and a group we do not read is a group
        // whose every line can be skipped on the cheapest possible test.
        if matches!(group, Group::Other) {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        // Only the unlocalised key wins; `Name[de]` and friends are skipped
        // rather than clobbering the value we already took. Real files rely on
        // this in both directions — `transmission-gtk.desktop` lists two dozen
        // `Name[xx]` translations *before* the plain `Name`.
        match group {
            Group::Main => match key {
                "Type" => kind = Some(value.to_string()),
                "Name" if name.is_none() => name = Some(value.to_string()),
                "Exec" if exec.is_none() => exec = Some(value.to_string()),
                "Icon" if icon.is_none() => icon = Some(value.to_string()),
                "Comment" if comment.is_none() => comment = Some(value.to_string()),
                "Terminal" => terminal = value == "true",
                "NoDisplay" => no_display = value == "true",
                "Hidden" => hidden = value == "true",
                // Trailing separators are allowed and common: `a;b;` and `a;b`
                // both name two actions.
                "Actions" if declared.is_empty() => {
                    declared = value.split(';').filter(|id| !id.is_empty()).collect();
                }
                _ => {}
            },
            Group::Action(id) => {
                let partial = groups.entry(id).or_default();
                match key {
                    "Name" if partial.name.is_none() => partial.name = Some(value.to_string()),
                    "Exec" if partial.exec.is_none() => partial.exec = Some(value.to_string()),
                    _ => {}
                }
            }
            Group::Other => {}
        }
    }

    if kind.as_deref() != Some("Application") || no_display || hidden {
        return None;
    }

    // `remove` rather than `get`, so an id repeated in `Actions=` yields the
    // action once instead of twice.
    let actions = declared
        .into_iter()
        .filter_map(|id| {
            let partial = groups.remove(id)?;
            Some(DesktopAction {
                id: id.to_string(),
                name: partial.name?,
                exec: partial.exec?,
            })
        })
        .collect();

    Some(DesktopEntry {
        name: name?,
        exec: exec?,
        icon,
        terminal,
        comment,
        actions,
    })
}

/// The id inside a group header, given everything after its opening `[…`.
///
/// Split out so the `[Desktop Action ` match can reject a malformed header
/// (`[Desktop Action Foo` with no closing bracket) by returning `None`, which
/// then falls through to the `[Desktop Entry]` comparison.
fn strip_header(rest: &str) -> Option<&str> {
    let id = rest.strip_suffix(']')?;
    (!id.is_empty()).then_some(id)
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
        ctx.apps
            .entries()
            .into_iter()
            .flat_map(|(id, entry)| {
                let parent_id = format!("apps:{id}");
                let exec = clean_exec(&entry.exec);
                let icon = entry.icon.as_deref().and_then(|name| ctx.apps.icon(name));

                // One child row per `[Desktop Action …]` group, built before
                // the parent so the parent's fields can still be moved into
                // it below.
                let children: Vec<Item> = entry
                    .actions
                    .iter()
                    .map(|action| {
                        Item::new(
                            format!("{parent_id}#{}", action.id),
                            action.name.clone(),
                            Action::Launch {
                                exec: clean_exec(&action.exec),
                                terminal: entry.terminal,
                            },
                        )
                        .parent(parent_id.clone())
                        // The app's name, so typing "libre" reaches its
                        // actions too, and so an action that outlives its
                        // parent in the filter still says what it belongs to.
                        .keywords([entry.name.as_str()])
                        .subtitle(entry.name.clone())
                        .icon(icon.clone())
                    })
                    .collect();

                let mut item = Item::new(
                    parent_id,
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
                // The same actions again on Ctrl+K. They are rows of their own
                // above, which is how you find one you did not know about;
                // this is how you reach one you did without leaving the app's
                // row. Raycast offers both for the same reason.
                for action in entry.actions {
                    item = item.alt(
                        action.name,
                        Action::Launch {
                            exec: clean_exec(&action.exec),
                            terminal: entry.terminal,
                        },
                    );
                }
                let item = item.alt(
                    "Open in terminal",
                    Action::Shell(format!("{} -e {}", ctx.config.terminal, exec)),
                );

                std::iter::once(item).chain(children)
            })
            .collect()
    }
}
