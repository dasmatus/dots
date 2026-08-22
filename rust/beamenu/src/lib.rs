//! beamenu, a Raycast-style launcher for Wayland.
//!
//! The crate splits in two. Everything here is ordinary Rust that can be
//! tested without a display: the row model, ranking, the providers, the
//! navigation stack. [`view`] is the exception, a thin FFI wrapper over the
//! patched `libbemenu` that draws the panel and reads the keyboard.
//!
//! That split is the point of the design. bemenu's event loop belongs to its
//! client, so beamenu becomes the client and rebuilds the item list between
//! keystrokes. No IPC, no second process, and every feature lands in code that
//! never touches Wayland.

pub mod config;
pub mod daemon;
pub mod dispatch;
pub mod frame;
pub mod frecency;
pub mod item;
pub mod providers;
pub mod rank;
pub mod view;

use anyhow::Result;

use crate::config::Config;
use crate::frame::{Frame, Stack};
use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

/// Everything the launcher needs to answer a query.
pub struct App {
    pub ctx: Ctx,
    pub providers: Vec<Box<dyn Provider>>,
    pub frecency: frecency::Frecency,
    pub stack: Stack,
}

impl App {
    /// Assemble from the on-disk configuration.
    #[must_use]
    pub fn new() -> Self {
        let config_dir = config::config_dir();
        let state_dir = config::state_dir();
        let config = Config::load(&config_dir.join("config.json"));
        let disabled = config.disabled.clone();

        let providers = providers::all(&config_dir)
            .into_iter()
            .filter(|p| !disabled.iter().any(|d| d == p.id()))
            .collect();

        Self {
            ctx: Ctx {
                config,
                config_dir,
                state_dir,
            },
            providers,
            frecency: frecency::Frecency::load(&frecency::default_path()),
            stack: Stack::new(),
        }
    }

    /// Rows for the current query, ranked.
    ///
    /// A pushed frame with fixed rows short-circuits: an action panel shows
    /// what it was built with, in the order it was built.
    #[must_use]
    pub fn results(&self, query: &str) -> Vec<Item> {
        if let Some(frame) = self.stack.top() {
            if frame.static_items {
                return frame.items.clone();
            }
        }

        let (mut items, rank_query) = providers::collect(&self.providers, &self.ctx, query);
        rank::rank(&mut items, &rank_query, |id| self.frecency.boost(id));
        items
    }

    /// Run an item's action, recording the launch for future ranking.
    ///
    /// A [`Action::Push`] never reaches here; the loop intercepts it, because
    /// pushing a frame is navigation rather than a side effect.
    ///
    /// # Errors
    /// Propagates dispatch failures; a frecency write failure is ignored,
    /// since losing ranking history must not block launching something.
    pub fn activate(&mut self, item: &Item) -> Result<()> {
        self.frecency.record(&item.id);
        let _ = self.frecency.save(&frecency::default_path());
        dispatch::dispatch(&item.action, &self.ctx.config.terminal)
    }

    /// Open the action panel for `item`, if it has alternate actions.
    pub fn open_actions(&mut self, item: &Item) -> bool {
        match Stack::actions_frame(item) {
            Some(frame) => {
                self.stack.push(frame);
                true
            }
            None => false,
        }
    }

    /// Pop a frame. Returns the query to restore, or `None` at the root.
    pub fn back(&mut self) -> Option<String> {
        self.stack.pop().map(|frame| frame.query)
    }
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

/// Drive the launcher until it is dismissed or an item is activated.
///
/// # Errors
/// Fails when no renderer can be opened, or when an activated action fails.
pub fn run(app: &mut App) -> Result<()> {
    let mut menu = view::Menu::new(&app.ctx.config)?;
    let mut shown = app.results("");
    menu.set_items(&shown);

    let mut last_query = String::new();

    loop {
        match menu.pump() {
            view::Outcome::Running { query } => {
                // Rebuilding on every frame would re-scan the desktop entries
                // for a keystroke that only moved the highlight.
                if query != last_query {
                    last_query.clone_from(&query);
                    shown = app.results(&query);
                    menu.set_items(&shown);
                }
            }
            view::Outcome::Selected { index } => {
                let Some(item) = shown.get(index).cloned() else {
                    continue;
                };
                if let Action::Push { provider, query } = &item.action {
                    app.stack.push(Frame {
                        items: Vec::new(),
                        query: last_query.clone(),
                        static_items: false,
                    });
                    let _ = provider;
                    menu.set_query(query);
                    last_query.clone_from(query);
                    shown = app.results(query);
                    menu.set_items(&shown);
                    continue;
                }
                app.activate(&item)?;
                return Ok(());
            }
            view::Outcome::Alternate { index } => {
                let Some(item) = shown.get(index).cloned() else {
                    continue;
                };
                if app.open_actions(&item) {
                    shown = app.results("");
                    menu.set_items(&shown);
                }
            }
            view::Outcome::Cancelled => {
                // Escape inside a pushed frame goes back one level rather than
                // closing, which is what makes the action panel feel like a
                // panel instead of a dead end.
                match app.back() {
                    Some(query) => {
                        menu.set_query(&query);
                        last_query.clone_from(&query);
                        shown = app.results(&query);
                        menu.set_items(&shown);
                    }
                    None => return Ok(()),
                }
            }
        }
    }
}
