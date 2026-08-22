//! File search, reached with a leading `f `.
//!
//! `fd` does the walking. It is fast enough to run synchronously on every
//! keystroke, which is why beamenu needs no asynchronous plumbing in the C
//! view: a query over a home directory returns in single-digit milliseconds,
//! well under the frame budget.
//!
//! Results are capped rather than streamed. A launcher list shows nine rows;
//! ranking a thousand candidates to display nine is wasted work, and the
//! query is almost always refined before the cap matters.

use std::path::{Path, PathBuf};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

pub struct Files;

/// Most paths asked of `fd` per query.
const RESULT_CAP: usize = 200;

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

fn search(query: &str, home: &Path) -> Vec<PathBuf> {
    let output = std::process::Command::new("fd")
        .args([
            "--hidden",
            "--follow",
            "--exclude",
            ".git",
            "--max-results",
            &RESULT_CAP.to_string(),
            query,
        ])
        .current_dir(home)
        .output();

    output
        .ok()
        .filter(|out| out.status.success())
        .map(|out| parse_output(&String::from_utf8_lossy(&out.stdout)))
        .unwrap_or_default()
        .into_iter()
        .map(|relative| home.join(relative))
        .collect()
}

impl Provider for Files {
    fn id(&self) -> &'static str {
        "files"
    }

    fn section(&self) -> &'static str {
        "Files"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix("f ")
    }

    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        let query = query.trim();
        // fd with an empty pattern lists the entire tree, which is never what
        // "f " on its own means.
        if query.is_empty() {
            return Vec::new();
        }

        let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
        search(query, &home)
            .into_iter()
            .map(|path| {
                let name = path.file_name().map_or_else(
                    || path.display().to_string(),
                    |n| n.to_string_lossy().into_owned(),
                );
                let quoted = format!("'{}'", path.display().to_string().replace('\'', r"'\''"));
                Item::new(
                    format!("file:{}", path.display()),
                    name,
                    Action::Shell(format!("xdg-open {quoted}")),
                )
                .subtitle(display_path(&path, &home))
                .accessory(if path.is_dir() { "Folder" } else { "File" })
                .alt(
                    "Reveal in file manager",
                    Action::Shell(format!("{} {quoted}", ctx.config.file_manager)),
                )
                .alt("Copy path", Action::Copy(path.display().to_string()))
            })
            .collect()
    }
}
