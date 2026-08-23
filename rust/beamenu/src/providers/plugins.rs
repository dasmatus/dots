//! Plugin manifests, one JSON file per plugin under
//! `$XDG_CONFIG_HOME/beamenu/plugins/*.json`.
//!
//! Home Manager renders these from `programs.beamenu.plugins`, one file per
//! attribute, so a plugin is declarative like snippets and quicklinks. Unlike
//! those, a plugin becomes its OWN [`Provider`]: its own section heading, its
//! own pill in the generic pill loop, and its own optional keyword — because
//! a plugin's commands are a coherent group (Raycast's "extension"), not rows
//! that belong folded into somebody else's list.
//!
//! Loading is tolerant: an unreadable file or invalid JSON is skipped rather
//! than failing the launcher, the same spirit as quicklinks and snippets.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

/// What activating a command does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Spawn `exec` detached, like [`Action::Launch`] with `terminal: false`.
    Exec,
    /// Spawn `exec` wrapped in the configured terminal.
    Terminal,
    /// Copy the `{query}`-substituted `exec`, joined into one shell command
    /// string, onto the clipboard. This does not run `exec`: the command
    /// text itself is the thing that gets copied, which is what keeps this
    /// mode a pure, testable string transform rather than something that
    /// depends on a child process's output.
    Copy,
    /// Open the `beamenu-canvas` sidecar on this command.
    View,
}

/// Sidecar renderer for a `view` command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Ui {
    #[default]
    Log,
    Rpc,
}

/// One command a plugin exposes as a row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Command {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    pub mode: Mode,
    #[serde(default)]
    pub ui: Ui,
    /// Argv. `{query}` in any element is replaced with the launcher query
    /// remainder before the command runs; see [`expand`].
    pub exec: Vec<String>,
    /// Extra rows for the Ctrl+K panel. One level deep: an action's own
    /// `actions` are ignored, since the panel is a flat list. Reusing
    /// [`Command`] rather than a trimmed twin keeps this parser and the
    /// canvas's deliberate duplicate from drifting apart field-by-field.
    #[serde(default)]
    pub actions: Vec<Command>,
}

/// A plugin manifest: `$XDG_CONFIG_HOME/beamenu/plugins/<name>.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    /// Stable identity. Becomes [`Provider::id`], so `disabledProviders` can
    /// name a plugin by it, and the manifest's filename matches it by
    /// convention (Nix writes `plugins/<name>.json`).
    pub name: String,
    /// Becomes [`Provider::section`], the heading its rows are grouped under.
    pub title: String,
    #[serde(default)]
    pub icon: Option<String>,
    /// The prefix that reaches this plugin, if any. Absent means ambient:
    /// every command is fuzzy-ranked into the root list like a quicklink.
    /// Matched at a word boundary: a trailing space is appended if the
    /// manifest did not already include one, so `"cl"` reaches this plugin on
    /// `"cl ask"` but not on `"clone"`. See [`keyword_trigger`].
    #[serde(default)]
    pub keyword: Option<String>,
    pub commands: Vec<Command>,
}

/// One plugin manifest, wearing the [`Provider`] trait.
///
/// `path` is kept alongside the parsed `manifest` because [`Action::View`]
/// hands the sidecar the manifest file itself rather than a copy of its
/// contents: the sidecar re-reads it and redoes `{query}` substitution on its
/// own, so the argv contract only needs a path, a command id and a query.
pub struct PluginProvider {
    pub manifest: Manifest,
    pub path: PathBuf,
}

/// Substitute `{query}` in every element of `exec`.
///
/// Mirrors `quicklinks::expand`'s placeholder rule, but per-argv-element
/// rather than into a single URL or command string: a plugin's `exec` is
/// already split the way `Command::new` wants it, and substituting before
/// that split would reopen the quoting problem that split was meant to avoid.
#[must_use]
pub fn expand(exec: &[String], query: &str) -> Vec<String> {
    exec.iter()
        .map(|arg| arg.replace("{query}", query))
        .collect()
}

/// Turn a manifest's `keyword` into a [`Trigger::Prefix`], appending a
/// trailing space when the author did not already include one.
///
/// Every built-in keyworded provider bakes a trailing space into its own
/// prefix (`"c "`, `"f "`, `"w "`) so a query only reaches it at a word
/// boundary. A plugin keyword gets the same treatment here rather than
/// trusting each manifest author to remember the space: without it, `"cl"`
/// would also swallow `"clone"` and `"class"`.
#[must_use]
fn keyword_trigger(keyword: &str) -> Trigger {
    if keyword.ends_with(char::is_whitespace) {
        Trigger::Prefix(keyword.to_string())
    } else {
        Trigger::Prefix(format!("{keyword} "))
    }
}

/// Join an argv into one shell command line, single-quoting each element.
///
/// Used wherever a plugin's `exec` has to become the single string
/// [`Action::Launch`] and [`Action::Copy`] carry, the same way
/// `scripts::query` quotes a script path before handing it to
/// [`Action::Shell`].
#[must_use]
fn shell_join(argv: &[String]) -> String {
    argv.iter()
        .map(|arg| format!("'{}'", arg.replace('\'', r"'\''")))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Load every plugin manifest directly inside `plugins_dir`.
///
/// A missing directory yields no plugins rather than an error: `plugins/`
/// might not exist yet, or every plugin might be undeclared. A file that
/// fails to read or fails to parse as a [`Manifest`] is skipped on its own,
/// so one broken manifest costs one plugin, not the launcher.
///
/// Sorted by name, since directory read order is not guaranteed and the
/// section order should not depend on filesystem happenstance.
#[must_use]
pub fn load_all(plugins_dir: &Path) -> Vec<PluginProvider> {
    let Ok(read) = std::fs::read_dir(plugins_dir) else {
        return Vec::new();
    };

    let mut providers: Vec<PluginProvider> = read
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("json"))
        .filter_map(|path| {
            let raw = std::fs::read_to_string(&path).ok()?;
            let manifest: Manifest = serde_json::from_str(&raw).ok()?;
            Some(PluginProvider { manifest, path })
        })
        .collect();

    providers.sort_by(|a, b| a.manifest.name.cmp(&b.manifest.name));
    providers
}

impl PluginProvider {
    /// Translate one command's (or action's) mode into an [`Action`], with
    /// `{query}` already expanded. `id` matters for `Mode::View`: the canvas
    /// looks the id up in the manifest itself, so an action's row must carry
    /// the action's id, not its parent command's.
    fn resolve(&self, id: &str, mode: Mode, exec: &[String], query: &str) -> Action {
        match mode {
            Mode::Exec => Action::Launch {
                exec: shell_join(&expand(exec, query)),
                terminal: false,
            },
            Mode::Terminal => Action::Launch {
                exec: shell_join(&expand(exec, query)),
                terminal: true,
            },
            Mode::Copy => Action::Copy(shell_join(&expand(exec, query))),
            Mode::View => Action::View {
                manifest: self.path.clone(),
                command: id.to_string(),
                query: query.to_string(),
            },
        }
    }

    /// Build the row for one command, given the already-stripped query text.
    fn item(&self, command: &Command, query: &str) -> Item {
        let action = self.resolve(&command.id, command.mode, &command.exec, query);

        let mut item = Item::new(
            format!("plugin:{}:{}", self.manifest.name, command.id),
            command.title.clone(),
            action,
        )
        .icon(self.manifest.icon.clone().map(PathBuf::from));

        if let Some(description) = &command.description {
            item = item.subtitle(description.clone());
        }

        for sub in &command.actions {
            item = item.alt(
                sub.title.clone(),
                self.resolve(&sub.id, sub.mode, &sub.exec, query),
            );
        }

        item
    }
}

impl Provider for PluginProvider {
    fn id(&self) -> &str {
        &self.manifest.name
    }

    fn section(&self) -> &str {
        &self.manifest.title
    }

    fn trigger(&self) -> Trigger {
        self.manifest
            .keyword
            .as_deref()
            .map_or(Trigger::Ambient, keyword_trigger)
    }

    fn query(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        // Keyworded plugins hand back every command unfiltered, same as
        // `window::Windows`: the keyword already narrowed the root list down
        // to this plugin, and the remainder is the `{query}` argument for
        // whichever command gets picked, not a further title filter. Ambient
        // plugins rely on the normal ranking pass in `providers::collect`
        // instead, exactly like quicklinks.
        let query = query.trim();
        self.manifest
            .commands
            .iter()
            .map(|command| self.item(command, query))
            .collect()
    }
}
