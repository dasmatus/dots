//! Result sources.
//!
//! A provider answers one question: given the current query, what rows do you
//! contribute? Everything Raycast calls a "core feature" is one of these, and
//! because a provider is a pure function of the query string plus a
//! [`Ctx`], the whole feature set is testable without a compositor.
//!
//! Providers fall into two kinds:
//!
//! * **Ambient.** Always contribute to the root list (apps, system commands,
//!   quicklinks, snippets). These are what you see before typing.
//! * **Keyworded.** Contribute only behind a prefix, because their results
//!   would otherwise drown the list (`=` calculator, `:` emoji, `c ` clipboard,
//!   `f ` files, `w ` windows).
//!
//! [`Ctx`]: Ctx

pub mod apps;
pub mod calc;
pub mod clipboard;
pub mod emoji;
pub mod files;
pub mod plugins;
pub mod quicklinks;
pub mod scripts;
pub mod snippets;
pub mod system;
pub mod window;

use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::item::Item;

/// Read-only environment handed to every provider.
pub struct Ctx {
    pub config: Config,
    /// `$XDG_CONFIG_HOME/beamenu`, where snippets, quicklinks and scripts live.
    pub config_dir: PathBuf,
    /// `$XDG_STATE_HOME/beamenu`, where the clipboard store and frecency live.
    pub state_dir: PathBuf,
}

/// How a provider is reached from the query line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Trigger {
    /// Always contributes to the root list.
    Ambient,
    /// Contributes only when the query starts with this prefix. The prefix is
    /// stripped before the provider sees the query.
    ///
    /// Owned rather than `&'static str` because a plugin's keyword comes from
    /// its JSON manifest at load time, not from a string literal.
    Prefix(String),
}

pub trait Provider {
    /// Stable identity, used by `Action::Push`, the frecency store and
    /// `Config::disabled`.
    ///
    /// Borrowed rather than `&'static str` because a plugin provider's id is
    /// its manifest's `name`, read from disk rather than known at compile
    /// time.
    fn id(&self) -> &str;

    /// Heading rows from this provider are grouped under.
    ///
    /// Borrowed for the same reason as [`Provider::id`]: a plugin's section
    /// is its manifest's `title`.
    fn section(&self) -> &str;

    /// How this provider is reached.
    fn trigger(&self) -> Trigger {
        Trigger::Ambient
    }

    /// Rows contributed for `query`, unranked and in any order.
    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item>;
}

/// Every provider, in the order their sections should appear.
///
/// `config_dir` is scanned once here for `plugins/*.json`, appending one
/// [`plugins::PluginProvider`] per manifest after the built-in providers.
/// beamenu spawns fresh per invocation, so a single scan at startup is always
/// current — there is no long-lived process to go stale.
#[must_use]
pub fn all(config_dir: &Path) -> Vec<Box<dyn Provider>> {
    let mut providers: Vec<Box<dyn Provider>> = vec![
        Box::new(calc::Calc),
        Box::new(apps::Apps),
        Box::new(quicklinks::Quicklinks),
        Box::new(snippets::Snippets),
        Box::new(scripts::Scripts),
        Box::new(window::Windows),
        Box::new(clipboard::Clipboard),
        Box::new(files::Files),
        Box::new(emoji::Emoji),
        Box::new(system::System),
    ];
    providers.extend(
        plugins::load_all(&config_dir.join("plugins"))
            .into_iter()
            .map(|provider| Box::new(provider) as Box<dyn Provider>),
    );
    providers
}

/// Rows for `query`, plus the text the caller should rank them against.
///
/// The two differ for keyworded providers: `=2+2` reaches the calculator with
/// `2+2`, and ranking against the full `=2+2` would then reject every row it
/// produced. Returning both keeps that knowledge here rather than making the
/// caller re-derive which prefix matched.
///
/// When a keyworded prefix matches, that provider answers alone. Typing `=2+2`
/// means the calculator, not the calculator plus every app whose name happens
/// to fuzzy-match.
#[must_use]
pub fn collect(providers: &[Box<dyn Provider>], ctx: &Ctx, query: &str) -> (Vec<Item>, String) {
    for provider in providers {
        if let Trigger::Prefix(prefix) = provider.trigger() {
            if let Some(rest) = query.strip_prefix(prefix.as_str()) {
                // A keyworded provider has already narrowed to exactly what
                // was asked for, so its rows are shown in the order it chose.
                return (decorate(provider.as_ref(), ctx, rest), String::new());
            }
        }
    }

    let items = providers
        .iter()
        .filter(|p| p.trigger() == Trigger::Ambient)
        .flat_map(|p| decorate(p.as_ref(), ctx, query))
        .collect();

    (items, query.to_string())
}

/// Run a provider and stamp its identity onto every row it returned, so a
/// provider never has to repeat its own heading.
///
/// The section is only filled in when the provider did not choose one itself,
/// since some rows want their own heading (`window`'s management actions, the
/// action panel's). The id is stamped unconditionally. Which provider produced
/// a row is a fact about it rather than a display choice, and the filter pill
/// bar needs every row to carry it.
fn decorate(provider: &dyn Provider, ctx: &Ctx, query: &str) -> Vec<Item> {
    provider
        .query(ctx, query)
        .into_iter()
        .map(|item| {
            let item = if item.section.is_some() {
                item
            } else {
                item.section(provider.section())
            };
            item.provider(provider.id())
        })
        .collect()
}
