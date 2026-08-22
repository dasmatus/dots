//! Text snippets, from `$XDG_CONFIG_HOME/beamenu/snippets.json`.
//!
//! Home Manager writes the file from `programs.beamenu.snippets`, so snippets
//! are declarative like everything else in this repo. Activating one pastes
//! it into the focused window; the alternate action copies instead.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

pub struct Snippets;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snippet {
    pub name: String,
    pub text: String,
    #[serde(default)]
    pub keyword: Option<String>,
}

/// Read snippets from `path`, treating absence or bad JSON as "none defined".
#[must_use]
pub fn load(path: &Path) -> Vec<Snippet> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

/// Collapse a snippet to one line for the subtitle, so a multi-line template
/// does not blow up the row.
#[must_use]
pub fn preview(text: &str) -> String {
    let single: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if single.chars().count() > 72 {
        let head: String = single.chars().take(71).collect();
        format!("{head}\u{2026}")
    } else {
        single
    }
}

impl Provider for Snippets {
    fn id(&self) -> &'static str {
        "snippets"
    }

    fn section(&self) -> &'static str {
        "Snippets"
    }

    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        load(&ctx.config_dir.join("snippets.json"))
            .into_iter()
            .map(|snippet| {
                Item::new(
                    format!("snippet:{}", snippet.name),
                    snippet.name.clone(),
                    Action::Paste(snippet.text.clone()),
                )
                .subtitle(preview(&snippet.text))
                .accessory(snippet.keyword.unwrap_or_else(|| "Snippet".to_string()))
                .alt("Copy", Action::Copy(snippet.text))
            })
            .collect()
    }
}
