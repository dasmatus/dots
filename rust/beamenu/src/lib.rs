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
pub mod http;
pub mod index;
pub mod ipc;
pub mod item;
pub mod palette;
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
    /// Assemble from the on-disk configuration, reusing an already-warm app
    /// cache.
    ///
    /// The cache is the one piece of an `App` worth carrying across a rebuild:
    /// everything else is a small file re-read in microseconds, while the
    /// desktop-entry scan is the expensive part the daemon exists to avoid
    /// repeating.
    fn with_cache(apps: index::AppCache) -> Self {
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
                apps,
            },
            providers,
            frecency: frecency::Frecency::load(&frecency::default_path()),
            stack: Stack::new(),
        }
    }

    /// Assemble from the on-disk configuration.
    #[must_use]
    pub fn new() -> Self {
        let app = Self::with_cache(index::AppCache::default());
        app.ctx.apps.revalidate();
        app
    }

    /// Re-read everything that lives on disk before showing the launcher again.
    ///
    /// A one-shot process got this for free by dying. A resident one has to
    /// ask: `config.json` and the plugin manifests are rewritten by a Home
    /// Manager switch, the frecency store may have been written by a
    /// `--command` invocation, and the navigation stack must not survive from
    /// whatever the last show was left in.
    pub fn refresh(&mut self) {
        let apps = std::mem::take(&mut self.ctx.apps);
        *self = Self::with_cache(apps);
        self.ctx.apps.revalidate();
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

    /// Rows for an [`Action::Present`], in exactly the order the provider
    /// returned them.
    ///
    /// Neither ranked nor regrouped, and that is the point. A provider reached
    /// this way has already decided what the answer is and what order it goes
    /// in — search results arrive in relevance order — so re-sorting here would
    /// only destroy it. `rank::group_by_section` in particular tie-breaks on
    /// title, which would alphabetise a result list whose rows all score zero.
    /// This mirrors `providers::collect` handing back an empty rank query for a
    /// keyworded provider, for the same reason. A provider returning more than
    /// one section is responsible for emitting them contiguously.
    ///
    /// Blocks for as long as the provider needs. Activating the row is what
    /// decided that was acceptable.
    #[must_use]
    pub fn present(&self, provider: &str, query: &str) -> Vec<Item> {
        providers::present(&self.providers, &self.ctx, provider, query)
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
        Self::spec_of(&self.visible(ambient))
    }

    /// The same spec, for a caller that already computed the visible set.
    ///
    /// `sync` needs the visible set anyway, to resolve the active pill, and
    /// recomputing it here would walk every row a second time.
    #[must_use]
    pub fn spec_of(visible: &[VisiblePill<'_>]) -> String {
        let mut spec = String::new();
        for pill in visible {
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
        Self::filter_of(ambient, &self.visible(ambient), active)
    }

    /// The same filter, for a caller that already computed the visible set.
    #[must_use]
    pub fn filter_of(ambient: &[Item], visible: &[VisiblePill<'_>], active: u32) -> Vec<Item> {
        // The sentinel means "nothing is filtering", which is the opposite of
        // an index that ran off the end, so it must not reach the fallback
        // below and narrow to the first pill. `sync` already routes around
        // this; honouring it here as well means a future caller of the public
        // filter/filter_of cannot silently reintroduce the bug.
        if active == view::BM_PILL_NONE {
            return ambient.to_vec();
        }

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

/// Which pill is active, remembered by the provider that owns it rather than
/// by its index.
///
/// `bm_menu_set_pills` takes an index into the array it is handed, and
/// Tab/Shift+Tab move that index inside the C library. The array is rebuilt
/// whenever the visible set changes, so an index means nothing across frames.
/// The same 2 can be System on one keystroke and Snippets on the next. Only
/// the provider id survives, so that is what this keeps.
/// The bar has two modes, and they are not the same thing.
///
/// With an empty query the launcher is browsing: the list is filtered to one
/// provider and Tab walks between them. Once something is typed the query
/// searches every provider instead, and the bar stops filtering and starts
/// reporting, marking whichever capsule names the highlighted row. Tab during
/// a search engages a provider again, intersecting it with the query, and the
/// next edit to the query releases that.
#[derive(Debug, Default)]
pub struct PillState {
    /// The provider chosen while browsing. Kept across query changes, so that
    /// clearing the query lands back where the user was.
    chosen: Option<String>,
    /// The provider Tab engaged during a search, intersected with the query.
    /// Cleared the moment the query changes.
    engaged: Option<String>,
    /// The provider ids last handed to `bm_menu_set_pills`, in the order they
    /// went over. A polled index only means anything against this list.
    sent: Vec<String>,
    /// The index last handed over, so that a poll echoing it back is not
    /// mistaken for the user pressing Tab.
    sent_index: u32,
}

impl PillState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The provider the bar is currently filtered to, if any.
    #[must_use]
    pub fn chosen(&self) -> Option<&str> {
        self.chosen.as_deref()
    }

    /// The provider Tab engaged during a search, if any.
    #[must_use]
    pub fn engaged(&self) -> Option<&str> {
        self.engaged.as_deref()
    }

    /// Resolve the wanted provider to an index into `visible`, recording what
    /// was sent so the next poll can be read back.
    ///
    /// Browsing resolves the chosen provider, falling back to the first
    /// visible pill when it has no rows this frame. The fallback does not
    /// overwrite the choice, so it returns as soon as it has rows again.
    /// Searching resolves the engaged provider instead, and answers
    /// [`view::BM_PILL_NONE`] when nothing is engaged, which is what tells the
    /// bar to report rather than filter.
    pub fn to_send(&mut self, visible: &[VisiblePill<'_>], searching: bool) -> u32 {
        self.sent = visible.iter().map(|pill| pill.id.to_string()).collect();

        let wanted = if searching {
            self.engaged.as_deref()
        } else {
            self.chosen.as_deref()
        };

        self.sent_index = match wanted
            .and_then(|id| visible.iter().position(|pill| pill.id == id))
            .and_then(|index| u32::try_from(index).ok())
        {
            Some(index) => index,
            None if searching => view::BM_PILL_NONE,
            None => 0,
        };
        self.sent_index
    }

    /// Adopt the index the C side reports, resolved against the ids last sent.
    ///
    /// Returns whether the choice actually moved. An echo of the index just
    /// sent is not a Tab press. A cleared bar reports 0 because `bm_pills_free`
    /// reset it, not because anyone picked the first pill, so a frame with
    /// nothing sent is ignored outright.
    ///
    /// A Tab during a search engages that provider on top of the query, and
    /// also updates the browsing choice, so clearing the query lands on the
    /// provider the user last tabbed to rather than somewhere else.
    pub fn on_poll(&mut self, polled: u32, searching: bool) -> bool {
        if self.sent.is_empty() || polled == self.sent_index {
            return false;
        }

        let Some(id) = self.sent.get(polled as usize) else {
            return false;
        };

        self.chosen = Some(id.clone());
        if searching {
            self.engaged = Some(id.clone());
        }
        self.sent_index = polled;
        true
    }

    /// Release the engaged provider, for when the query changes.
    pub fn on_query_change(&mut self) {
        self.engaged = None;
    }

    /// Forget what was sent, for the frames that clear the bar.
    pub fn cleared(&mut self) {
        self.sent.clear();
        self.sent_index = 0;
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
    state: &mut PillState,
) -> Vec<Item> {
    let ambient = app.results(query);

    if !app.stack.is_empty() {
        menu.set_pills("", 0);
        state.cleared();
        menu.set_items(&ambient);
        return ambient;
    }

    let visible = pills.visible(&ambient);
    let active = state.to_send(&visible, !query.is_empty());
    menu.set_pills(&Pills::spec_of(&visible), active);

    let shown = if active == view::BM_PILL_NONE {
        ambient
    } else {
        Pills::filter_of(&ambient, &visible, active)
    };

    menu.set_items(&shown);
    shown
}

/// Open a panel and drive it until it is dismissed or an item is activated.
///
/// # Errors
/// Fails when no renderer can be opened, or when an activated action fails.
pub fn run(app: &mut App) -> Result<()> {
    let menu = view::Menu::new(&app.ctx.config)?;
    run_with(menu, app)
}

/// Drive an already-open panel until it is dismissed or an item is activated.
///
/// Split from [`run`] for the daemon's sake. A one-shot process can treat
/// both failures alike, since either way it is about to exit. A resident one
/// cannot: an action that failed is somebody's missing `wl-copy` and the
/// daemon should keep serving, while a panel that would not open means the
/// display is gone and every later show would fail the same way. Handing the
/// caller the [`view::Menu`] is what lets it tell those apart.
///
/// # Errors
/// Fails when an activated action fails.
pub fn run_with(mut menu: view::Menu, app: &mut App) -> Result<()> {
    let pills = Pills::new(&app.providers);

    let mut last_query = String::new();
    let mut state = PillState::new();
    let mut shown = sync(&mut menu, app, &last_query, &pills, &mut state);

    loop {
        match menu.pump() {
            view::Outcome::Running { query } => {
                // Rebuilding on every frame would re-scan the desktop entries
                // for a keystroke that only moved the highlight.
                let mut dirty = query != last_query;
                if dirty {
                    last_query.clone_from(&query);
                    state.on_query_change();
                }

                // Polling only at the root keeps a Tab press inside the
                // action panel doing what it always did (highlight-next):
                // the pill bar is cleared there, so the C side never
                // intercepts Tab in the first place, but this still avoids
                // reading back a stale index while it's inert.
                if app.stack.is_empty() && state.on_poll(menu.active_pill(), !last_query.is_empty())
                {
                    dirty = true;
                }

                if dirty {
                    shown = sync(&mut menu, app, &last_query, &pills, &mut state);
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
                    shown = sync(&mut menu, app, query, &pills, &mut state);
                    continue;
                }
                if let Action::Present { provider, query } = &item.action {
                    // The expensive call, made exactly once. Everything it
                    // returns is fixed from here, so the frame is static and
                    // `App::results` short-circuits to it without re-querying
                    // any provider.
                    let items = app.present(provider, query);
                    app.frecency.record(&item.id);
                    let _ = app.frecency.save(&frecency::default_path());
                    app.stack.push(Frame {
                        items,
                        query: last_query.clone(),
                        static_items: true,
                    });
                    // The search line keeps the terms that produced the list,
                    // so the frame says what it is an answer to. Safe because
                    // the C side runs in BM_FILTER_MODE_NONE and never filters
                    // on its own.
                    menu.set_query(query);
                    last_query.clone_from(query);
                    shown = sync(&mut menu, app, &last_query, &pills, &mut state);
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
                    shown = sync(&mut menu, app, "", &pills, &mut state);
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
                        shown = sync(&mut menu, app, &last_query, &pills, &mut state);
                    }
                    None => return Ok(()),
                }
            }
        }
    }
}
