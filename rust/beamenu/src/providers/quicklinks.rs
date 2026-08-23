//! Quicklinks, from `$XDG_CONFIG_HOME/beamenu/quicklinks.json`.
//!
//! A quicklink is a URL or command with an optional `{query}` placeholder.
//! Typing past the link's name fills the placeholder, so `gh nixpkgs` opens a
//! GitHub search for nixpkgs. Without a placeholder it is just a bookmark.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

pub struct Quicklinks;

/// The substring replaced with whatever the user typed after the link name.
pub const PLACEHOLDER: &str = "{query}";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Quicklink {
    pub name: String,
    /// A URL, or a shell command when `command` is true.
    pub target: String,
    #[serde(default)]
    pub command: bool,
    #[serde(default)]
    pub icon: Option<String>,
}

#[must_use]
pub fn load(path: &Path) -> Vec<Quicklink> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

/// Substitute `argument` into `target`.
///
/// URL targets get the argument percent-encoded, because a quicklink almost
/// always drops it into a query string and a raw space would break the URL.
/// Command targets are single-quoted instead, since they go through a shell.
#[must_use]
pub fn expand(target: &str, argument: &str, command: bool) -> String {
    if !target.contains(PLACEHOLDER) {
        return target.to_string();
    }
    let encoded = if command {
        format!("'{}'", argument.replace('\'', r"'\''"))
    } else {
        percent_encode(argument)
    };
    target.replace(PLACEHOLDER, &encoded)
}

/// Percent-encode everything outside the RFC 3986 unreserved set.
#[must_use]
pub fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => {
                use std::fmt::Write;
                let _ = write!(out, "%{byte:02X}");
            }
        }
    }
    out
}

impl Provider for Quicklinks {
    fn id(&self) -> &'static str {
        "quicklinks"
    }

    fn section(&self) -> &'static str {
        "Quicklinks"
    }

    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        load(&ctx.config_dir.join("quicklinks.json"))
            .into_iter()
            .map(|link| {
                // Anything typed past the link's own name becomes the
                // argument, so "gh nixpkgs" fills {query} with "nixpkgs".
                let argument = query
                    .strip_prefix(&link.name)
                    .map_or("", str::trim)
                    .to_string();
                let target = expand(&link.target, &argument, link.command);
                let action = if link.command {
                    Action::Shell(target.clone())
                } else {
                    Action::OpenUrl(target.clone())
                };
                Item::new(
                    format!("quicklink:{}", link.name),
                    link.name.clone(),
                    action,
                )
                .subtitle(target)
                .icon(link.icon.map(std::path::PathBuf::from))
            })
            .collect()
    }
}
