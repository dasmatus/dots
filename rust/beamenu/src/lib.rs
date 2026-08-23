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

/// The filter pill bar's ordered model: one pill per ambient provider, in
/// registry order.
///
/// Built once from [`providers::all`]'s registry order rather than naming
/// any provider, so a later plugin provider earns a pill with zero changes
/// here. Keyworded providers (`=`, `:`, `c `, `f `, `w `) are prefix-triggered
/// modes rather than list-and-filter sources and are left out.
///
/// This is the registry of every pill that could appear. [`Pills::visible`]
/// decides which ones actually do on a given frame, since a provider with no
/// rows earns no pill.
pub struct Pills {
    pills: Vec<Pill>,
}

/// One registered pill: the provider that owns it, and the text it shows.
struct Pill {
    id: String,
    label: String,
}

/// A pill that has rows on the frame being drawn.
///
/// `id` is what [`Pills::filter`] matches rows against. `label` is what the
/// capsule shows. They differ whenever two providers share a heading.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VisiblePill<'a> {
    pub id: &'a str,
    pub label: &'a str,
    pub count: usize,
}

impl Pills {
    /// Register one pill per ambient provider, in registry order.
    ///
    /// Owned rather than borrowed: a plugin provider's id and section are its
    /// manifest's `name` and `title`, read from disk, so neither has a
    /// `'static` lifetime to borrow.
    ///
    /// Every provider gets its own pill, including every plugin. Nothing here
    /// names one. The set is whatever [`providers::all`] registered, so a
    /// manifest dropped into `plugins/` earns a pill with no code change.
    /// Keying on id rather than on heading is what lets two plugins that chose
    /// the same `title` still get one pill each.
    #[must_use]
    pub fn new(providers: &[Box<dyn Provider>]) -> Self {
        Self {
            pills: providers
                .iter()
                .filter(|p| p.trigger() == Trigger::Ambient)
                .map(|p| Pill {
                    id: p.id().to_string(),
                    label: p.section().to_string(),
                })
                .collect(),
        }
    }

    /// Every registered pill's label, in registry order, whether or not it
    /// currently has rows.
    #[must_use]
    pub fn labels(&self) -> Vec<&str> {
        self.pills.iter().map(|pill| pill.label.as_str()).collect()
    }

    /// Every registered pill's owning provider id, in registry order.
    #[must_use]
    pub fn ids(&self) -> Vec<&str> {
        self.pills.iter().map(|pill| pill.id.as_str()).collect()
    }

    /// The pills that have at least one row in `ambient`, in registry order.
    ///
    /// [`Pills::spec`] renders this list and [`Pills::filter`] indexes it, so
    /// pill N names the same provider on both sides of the FFI. Nothing else
    /// may decide what an index means.
    #[must_use]
    pub fn visible<'a>(&'a self, ambient: &[Item]) -> Vec<VisiblePill<'a>> {
        self.pills
            .iter()
            .filter_map(|pill| {
                let count = ambient
                    .iter()
                    .filter(|item| item.provider.as_deref() == Some(pill.id.as_str()))
                    .count();
                (count > 0).then_some(VisiblePill {
                    id: &pill.id,
                    label: &pill.label,
                    count,
                })
            })
            .collect()
    }

    /// The `bm_menu_set_pills` spec for `ambient`: one `\x1f`-separated
    /// `label:count` entry per visible pill, in registry order.
    ///
    /// Empty when nothing is visible, which happens on a keyword query or on a
    /// query no ambient row matched. The C side reads that as "no bar" and
    /// reclaims the row's height rather than drawing an empty strip.
    #[must_use]
    pub fn spec(&self, ambient: &[Item]) -> String {
        let mut spec = String::new();
        for pill in self.visible(ambient) {
            if !spec.is_empty() {
                spec.push('\u{1f}');
            }
            spec.push_str(pill.label);
            spec.push(':');
            spec.push_str(&pill.count.to_string());
        }
        spec
    }

    /// Rows to display for pill `active`: only the rows whose section is that
    /// pill's, indexing [`Pills::visible`].
    ///
    /// An index past the end falls back to the first visible pill rather than
    /// to the whole mix, so a stale index narrows to something real instead of
    /// silently dropping the filter. With nothing visible at all there is no
    /// pill to honour, so `ambient` passes through untouched.
    ///
    /// Filtering `ambient` rather than re-querying the provider directly
    /// gives the same rows either way — `rank::rank` only drops non-matches,
    /// it never truncates — while keeping this a pure function of results
    /// [`App::results`] already computed.
    #[must_use]
    pub fn filter(&self, ambient: &[Item], active: u32) -> Vec<Item> {
        let visible = self.visible(ambient);
        let Some(pill) = visible.get(active as usize).or_else(|| visible.first()) else {
            return ambient.to_vec();
        };

        ambient
            .iter()
            .filter(|item| item.provider.as_deref() == Some(pill.id))
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
