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
use crate::providers::{Ctx, Provider, Trigger};

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

        let providers = providers::all()
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

/// The filter pill bar's ordered model: `All` plus one pill per ambient
/// provider, in registry order.
///
/// Built once from [`providers::all`]'s registry order rather than naming
/// any provider, so a later plugin provider earns a pill with zero changes
/// here. Keyworded providers (`=`, `:`, `c `, `f `, `w `) are prefix-triggered
/// modes rather than list-and-filter sources and are left out.
pub struct Pills {
    labels: Vec<&'static str>,
}

impl Pills {
    /// Collect the ambient providers' section labels, in registry order.
    #[must_use]
    pub fn new(providers: &[Box<dyn Provider>]) -> Self {
        Self {
            labels: providers
                .iter()
                .filter(|p| p.trigger() == Trigger::Ambient)
                .map(|p| p.section())
                .collect(),
        }
    }

    /// Section labels, in the same order as pill indices 1.. (index 0 is
    /// always `All`, which has no section of its own).
    #[must_use]
    pub fn labels(&self) -> &[&'static str] {
        &self.labels
    }

    /// The `bm_menu_set_pills` spec for `ambient`: `All:<total>` followed by
    /// one `\x1f`-separated `label:count` entry per pill, in registry order.
    #[must_use]
    pub fn spec(&self, ambient: &[Item]) -> String {
        let mut counts = vec![0usize; self.labels.len()];
        for item in ambient {
            if let Some(section) = item.section.as_deref() {
                if let Some(i) = self.labels.iter().position(|label| *label == section) {
                    counts[i] += 1;
                }
            }
        }

        let mut spec = format!("All:{}", ambient.len());
        for (label, count) in self.labels.iter().zip(&counts) {
            spec.push('\u{1f}');
            spec.push_str(label);
            spec.push(':');
            spec.push_str(&count.to_string());
        }
        spec
    }

    /// Rows to display for pill `active`: every ambient row for pill 0
    /// (`All`), or only the rows whose section is that pill's provider.
    ///
    /// Filtering `ambient` rather than re-querying the provider directly
    /// gives the same rows either way — `rank::rank` only drops non-matches,
    /// it never truncates — while keeping this a pure function of results
    /// [`App::results`] already computed.
    #[must_use]
    pub fn filter(&self, ambient: &[Item], active: u32) -> Vec<Item> {
        let label = active
            .checked_sub(1)
            .and_then(|i| self.labels.get(i as usize));

        let Some(label) = label else {
            return ambient.to_vec();
        };

        ambient
            .iter()
            .filter(|item| item.section.as_deref() == Some(*label))
            .cloned()
            .collect()
    }
}

/// Recompute the pill bar and the row list together and push both to the
/// menu, returning the rows now shown.
///
/// Pills are root-only: a pushed frame (the Ctrl+K action panel, or a future
/// `Action::Push` continuation) clears the bar rather than show providers
/// that frame's rows have nothing to do with. With the bar cleared,
/// `bm_menu_get_active_pill` reads back whatever it last was and
/// Tab/Shift+Tab fall through to their stock bindings again (the C side only
/// intercepts them while `pill_count > 0`), which is the behaviour an action
/// panel wants.
fn sync(
    menu: &mut view::Menu,
    app: &App,
    query: &str,
    pills: &Pills,
    active_pill: u32,
) -> Vec<Item> {
    let ambient = app.results(query);

    if !app.stack.is_empty() {
        menu.set_pills("", 0);
        menu.set_items(&ambient);
        return ambient;
    }

    menu.set_pills(&pills.spec(&ambient), active_pill);
    let shown = pills.filter(&ambient, active_pill);
    menu.set_items(&shown);
    shown
}

/// Drive the launcher until it is dismissed or an item is activated.
///
/// # Errors
/// Fails when no renderer can be opened, or when an activated action fails.
pub fn run(app: &mut App) -> Result<()> {
    let mut menu = view::Menu::new(&app.ctx.config)?;
    let pills = Pills::new(&app.providers);

    let mut last_query = String::new();
    let mut active_pill: u32 = 0;
    let mut shown = sync(&mut menu, app, &last_query, &pills, active_pill);

    loop {
        match menu.pump() {
            view::Outcome::Running { query } => {
                // Rebuilding on every frame would re-scan the desktop entries
                // for a keystroke that only moved the highlight.
                let mut dirty = query != last_query;
                if dirty {
                    last_query.clone_from(&query);
                }

                // Polling only at the root keeps a Tab press inside the
                // action panel doing what it always did (highlight-next):
                // the pill bar is cleared there, so the C side never
                // intercepts Tab in the first place, but this still avoids
                // reading back a stale index while it's inert.
                if app.stack.is_empty() {
                    let polled = menu.active_pill();
                    if polled != active_pill {
                        active_pill = polled;
                        dirty = true;
                    }
                }

                if dirty {
                    shown = sync(&mut menu, app, &last_query, &pills, active_pill);
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
                    shown = sync(&mut menu, app, query, &pills, active_pill);
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
                    shown = sync(&mut menu, app, "", &pills, active_pill);
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
                        shown = sync(&mut menu, app, &last_query, &pills, active_pill);
                    }
                    None => return Ok(()),
                }
            }
        }
    }
}
