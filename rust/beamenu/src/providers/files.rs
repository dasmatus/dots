//! File search, in the root list and behind a leading `f `.
//!
//! `fd` does the walking. It is fast enough to run synchronously on every
//! keystroke, which is why beamenu needs no asynchronous plumbing in the C
//! view: a query over a home directory returns in single-digit milliseconds,
//! well under the frame budget.
//!
//! Results are capped rather than streamed. A launcher list shows nine rows;
//! ranking a thousand candidates to display nine is wasted work, and the
//! query is almost always refined before the cap matters.
//!
//! Two providers, one search. Files belong in the root list beside
//! applications, because a name is a name and nobody wants to remember which
//! prefix reaches which kind of thing. But the root list runs on every
//! keystroke a person types all day, and an unbounded walk of a home
//! directory there is a different proposition from one behind a prefix
//! somebody asked for. So the ambient half is deliberately shallow and
//! short-capped, and `f ` keeps the exhaustive search for when the shallow
//! one came up empty. `providers::collect` routes a prefixed query to
//! exactly one provider, so the two never both run and never duplicate a row.

use std::path::{Path, PathBuf};

use crate::item::{Action, FileOp, Item, Preview};
use crate::providers::{Ctx, Provider, Trigger};

/// How far a search reaches, and what it costs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// The root list: shallow, short-capped, and silent on a query too short
    /// to mean anything.
    Ambient,
    /// Behind `f `: the whole tree, however long that takes.
    Deep,
}

pub struct Files {
    pub scope: Scope,
}

/// Most paths asked of `fd` per `f ` query.
const RESULT_CAP: usize = 200;

/// Most paths asked of `fd` per root-list query.
///
/// Far below [`RESULT_CAP`], because these rows are ranked against every
/// application, snippet and quicklink rather than shown on their own. Forty
/// candidates is already more than can win nine slots against that field.
const AMBIENT_CAP: usize = 40;

/// How deep the root-list search walks.
///
/// Bounding the walk is what makes it affordable on every keystroke. Five
/// levels covers where things people are looking for actually live
/// (`~/Downloads/x`, `~/Dokumente/codeberg/personal/dots/README.md`) and stops
/// short of the directories that make a home directory expensive to walk:
/// `node_modules`, `.cargo/registry`, a nested checkout's `target`.
const AMBIENT_MAX_DEPTH: usize = 5;

/// Shortest root-list query worth searching for.
///
/// One or two characters match most of a filesystem, so the walk runs to the
/// cap every time and returns rows nobody meant. Behind `f ` a single
/// character is honoured, because typing the prefix was the request.
const AMBIENT_MIN_QUERY: usize = 3;

/// Turn `fd` output into paths, dropping blank lines.
#[must_use]
pub fn parse_output(stdout: &str) -> Vec<PathBuf> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .collect()
}

/// Shorten a path for display by collapsing the home prefix to `~`.
#[must_use]
pub fn display_path(path: &Path, home: &Path) -> String {
    path.strip_prefix(home).map_or_else(
        |_| path.display().to_string(),
        |rest| format!("~/{}", rest.display()),
    )
}

fn search(query: &str, home: &Path, scope: Scope) -> Vec<PathBuf> {
    let mut command = std::process::Command::new("fd");
    command.args(["--hidden", "--follow", "--exclude", ".git", "--max-results"]);

    match scope {
        Scope::Ambient => {
            command.arg(AMBIENT_CAP.to_string());
            command.args(["--max-depth", &AMBIENT_MAX_DEPTH.to_string()]);
        }
        Scope::Deep => {
            command.arg(RESULT_CAP.to_string());
        }
    }

    let output = command.arg(query).current_dir(home).output();

    output
        .ok()
        .filter(|out| out.status.success())
        .map(|out| parse_output(&String::from_utf8_lossy(&out.stdout)))
        .unwrap_or_default()
        .into_iter()
        .map(|relative| home.join(relative))
        .collect()
}

/// Add the file-manager actions to a row, in the order the Ctrl+K panel shows
/// them.
///
/// Ordered by how much they cost to get wrong, mildest first. The three that
/// need a name come before the two that destroy something, and the two that
/// destroy something are the last things on the list, where a mis-aimed Enter
/// is least likely to land.
///
/// Trash and Delete are separate rows rather than one row with a modifier,
/// because they are different promises. Trash is undoable through the file
/// manager and needs no confirmation; Delete is not, and gets one.
///
/// "New folder" hangs off a file row as well as a directory row, and makes
/// the folder next to the file rather than inside it. Somebody who found a
/// file and wants a folder beside it has already navigated to the right
/// place, and making them find the directory row first would be pedantry.
#[must_use]
fn with_file_actions(item: Item, path: &Path) -> Item {
    let parent = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent().unwrap_or(path).to_path_buf()
    };

    item.alt(
        "New folder…",
        Action::Prompt {
            op: FileOp::NewFolder { parent },
        },
    )
    .alt(
        "Rename…",
        Action::Prompt {
            op: FileOp::Rename {
                target: path.to_path_buf(),
            },
        },
    )
    .alt(
        "Move to…",
        Action::Prompt {
            op: FileOp::MoveTo {
                target: path.to_path_buf(),
            },
        },
    )
    .alt(
        "Move to Trash",
        Action::File {
            op: FileOp::Trash {
                target: path.to_path_buf(),
            },
            argument: String::new(),
        },
    )
    .alt(
        "Delete permanently",
        Action::Confirm {
            label: format!("Delete {} permanently", short_name(path)),
            action: Box::new(Action::File {
                op: FileOp::Delete {
                    target: path.to_path_buf(),
                },
                argument: String::new(),
            }),
        },
    )
}

fn short_name(path: &Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}

/// Whether `query` is worth walking a filesystem for at this scope.
///
/// Exposed so the rule is testable without `fd` on the machine running the
/// tests, and so it stays one rule rather than a condition duplicated per
/// call site.
#[must_use]
pub fn worth_searching(query: &str, scope: Scope) -> bool {
    // fd with an empty pattern lists the entire tree, which is never what
    // either mode means.
    match scope {
        Scope::Deep => !query.is_empty(),
        Scope::Ambient => query.chars().count() >= AMBIENT_MIN_QUERY,
    }
}

impl Provider for Files {
    fn id(&self) -> &'static str {
        match self.scope {
            Scope::Ambient => "files",
            // A distinct id, so the two are separately nameable in
            // `disabledProviders` and the ambient half keeps the one pill.
            // `Pills::new` registers ambient providers only, so the deep half
            // earns none, which is right: it is a mode, not a section.
            Scope::Deep => "files-deep",
        }
    }

    fn section(&self) -> &'static str {
        "Files"
    }

    fn trigger(&self) -> Trigger {
        match self.scope {
            Scope::Ambient => Trigger::Ambient,
            Scope::Deep => Trigger::Prefix("f ".to_string()),
        }
    }

    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        let query = query.trim();
        if !worth_searching(query, self.scope) {
            return Vec::new();
        }

        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        search(query, &home, self.scope)
            .into_iter()
            .map(|path| {
                let name = path.file_name().map_or_else(
                    || path.display().to_string(),
                    |n| n.to_string_lossy().into_owned(),
                );
                let quoted = format!("'{}'", path.display().to_string().replace('\'', r"'\''"));
                let mut item = Item::new(
                    format!("file:{}", path.display()),
                    name,
                    // Enter opens the file the way the desktop would open it,
                    // which on Linux is what `xdg-open` means: it resolves the
                    // MIME association rather than naming an application, so a
                    // .png goes to the image viewer and a .rs to the editor.
                    Action::Shell(format!("xdg-open {quoted}")),
                )
                .subtitle(display_path(&path, &home))
                // The pane opens the file; this side never does. What it draws
                // (a thumbnail, the first lines of text, a directory listing)
                // is its decision, made from bytes only it has read.
                .preview(Preview::File { path: path.clone() })
                .alt(
                    "Reveal in file manager",
                    Action::Shell(format!("{} {quoted}", ctx.config.file_manager)),
                )
                .alt("Copy path", Action::Copy(path.display().to_string()));

                item = with_file_actions(item, &path);

                // The one thing the pane would have to walk back up the tree
                // to work out, and the row already knows. Everything else
                // under the preview (size, kind, when it changed) comes from
                // the stat the pane is doing anyway.
                if let Some(parent) = path.parent() {
                    item = item.meta("Where", display_path(parent, &home));
                }
                item
            })
            .collect()
    }
}
