//! Result sources.
//!
//! A provider answers one question: given the current query, what rows do you
//! contribute? Everything Raycast calls a "core feature" is one of these, and
//! because a provider sees nothing but the query string and a [`Ctx`], the
//! whole feature set is testable without a compositor.
//!
//! Providers fall into two kinds by how they are *reached*:
//!
//! * **Ambient.** Always contribute to the root list (apps, system commands,
//!   quicklinks, snippets, status). These are what you see before typing.
//! * **Keyworded.** Contribute only behind a prefix, because their results
//!   would otherwise drown the list (`=` calculator, `:` emoji, `c ` clipboard,
//!   `f ` files, `w ` windows, `s ` web search).
//!
//! And into two kinds again by what they *cost*. [`Provider::query`] runs on
//! every keystroke and must stay inside the frame budget — reading `/proc` or
//! walking a directory is fine, a network round trip is not.
//! [`Provider::present`] runs once, when the user activated a row that asked
//! for it, and may block for as long as the answer takes.
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
pub mod status;
pub mod system;
pub mod websearch;
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
    /// Desktop entries and icon paths, kept warm across shows. See
    /// [`crate::index::AppCache`].
    pub apps: crate::index::AppCache,
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
    ///
    /// Runs on every keystroke, so it must stay inside the frame budget. The
    /// launcher renders before it blocks for the next key, which means a slow
    /// provider does not merely lag the list — it delays the character just
    /// typed from appearing at all.
    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item>;

    /// Rows for an explicit activation rather than a keystroke.
    ///
    /// Reached only through [`Action::Present`], so it runs once, when the
    /// user pressed Enter on a row that asked for it. That is the whole point:
    /// this one may block on the network or on a subprocess, where
    /// [`Provider::query`] may not.
    ///
    /// Defaults to [`Provider::query`], so a provider with nothing expensive
    /// to offer needs no opinion about this.
    ///
    /// [`Action::Present`]: crate::item::Action::Present
    fn present(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        self.query(ctx, query)
    }
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
        Box::new(websearch::WebSearch),
        Box::new(system::System),
        Box::new(status::Status),
    ];
    providers.extend(
        plugins::load_all(&config_dir.join("plugins"))
            .into_iter()
            .map(|provider| Box::new(provider) as Box<dyn Provider>),
    );
    providers
}

/// Rows from one named provider's [`Provider::present`], stamped the same way
/// [`collect`] stamps its own.
///
/// An id naming no registered provider yields no rows rather than an error:
/// the id travels inside an [`Action::Present`] that a provider built, so a
/// miss means a provider named itself wrongly or was disabled between building
/// the row and activating it. Neither is worth failing the launcher over.
///
/// [`Action::Present`]: crate::item::Action::Present
#[must_use]
pub fn present(providers: &[Box<dyn Provider>], ctx: &Ctx, id: &str, query: &str) -> Vec<Item> {
    providers
        .iter()
        .find(|provider| provider.id() == id)
        .map(|provider| stamp(provider.as_ref(), provider.present(ctx, query)))
        .unwrap_or_default()
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

/// Stamp a provider's identity onto every row it returned, so a provider never
/// has to repeat its own heading.
///
/// The section is only filled in when the provider did not choose one itself,
/// since some rows want their own heading (`window`'s management actions, the
/// action panel's). The id is stamped unconditionally. Which provider produced
/// a row is a fact about it rather than a display choice, and the filter pill
/// bar needs every row to carry it.
///
/// Takes rows rather than calling the provider, because the two callers differ
/// in which method produced them: [`collect`] runs [`Provider::query`] and
/// [`present`] runs [`Provider::present`], and both must stamp identically.
fn stamp(provider: &dyn Provider, items: Vec<Item>) -> Vec<Item> {
    items
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

/// Run a provider's per-keystroke [`Provider::query`] and stamp the result.
fn decorate(provider: &dyn Provider, ctx: &Ctx, query: &str) -> Vec<Item> {
    stamp(provider, provider.query(ctx, query))
}
