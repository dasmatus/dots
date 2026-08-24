//! The row model and the actions a row can perform.
//!
//! An [`Item`] is what one line of the launcher shows and what happens when
//! you press Enter on it. Providers build these; `view` turns them into
//! `bm_item`s; [`Action`] is executed by `crate::dispatch`.

use std::path::PathBuf;

/// What activating a row does.
///
/// Every variant is data, never a closure, so a provider's output stays
/// comparable and testable without running anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Run a desktop-entry `Exec` line, optionally inside a terminal.
    Launch { exec: String, terminal: bool },
    /// Run a shell command detached from the launcher.
    Shell(String),
    /// Put text on the clipboard.
    Copy(String),
    /// Put text on the clipboard and paste it into the focused window.
    Paste(String),
    /// Open a URL in the default browser.
    OpenUrl(String),
    /// Focus a Hyprland client by address.
    FocusWindow(String),
    /// Open the `beamenu-canvas` sidecar on one plugin command.
    ///
    /// `manifest` is the plugin's manifest file, `command` the id of the
    /// command within it, and `query` the launcher query remainder captured
    /// when the row was activated. Rebuilding the argv (rather than shipping
    /// `exec` here) keeps the `{query}` substitution rule in one place: the
    /// canvas re-reads the manifest and re-substitutes itself.
    View {
        manifest: PathBuf,
        command: String,
        query: String,
    },
    /// Descend into another provider's list instead of closing the launcher.
    Push { provider: String, query: String },
    /// Replace the list with rows only `provider` can produce, computed once
    /// at activation.
    ///
    /// Distinct from [`Action::Push`] in where the work happens. A provider's
    /// `query` runs on every keystroke and must stay inside the frame budget;
    /// this runs once, because the user asked for it. That is what lets a row
    /// cost a network round trip or a subprocess without that cost landing on
    /// every character typed. See [`crate::providers::Provider::present`].
    Present { provider: String, query: String },
    /// Do nothing. Used by informational rows such as a calculator result
    /// that has already been copied.
    None,
}

/// One row of the launcher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    /// Stable identity, used by the frecency store. Providers must keep this
    /// constant across runs for the same logical entry.
    pub id: String,
    /// Primary text, and the first thing the filter matches against.
    pub title: String,
    /// Extra words the filter matches but the row never shows.
    ///
    /// For rows whose name is not what anyone types. A status row titled
    /// "Network" has to answer to "wifi" and "ssid", and folding those into the
    /// title would put them on screen forever to serve a search that lasts a
    /// keystroke.
    ///
    /// Scored one at a time rather than as one joined string, because
    /// `rank::score` matches subsequences: a long haystack accidentally
    /// contains far more needles than a short one, so a joined blob would
    /// match queries none of its words do.
    pub keywords: Vec<String>,
    /// Muted text drawn after the title.
    pub subtitle: Option<String>,
    /// Right-aligned trailing text.
    pub accessory: Option<String>,
    /// Path to an icon file; SVG and PNG render, anything else is ignored.
    pub icon: Option<PathBuf>,
    /// Heading this row is grouped under.
    pub section: Option<String>,
    /// Id of the provider that produced this row, stamped by
    /// `providers::decorate`.
    ///
    /// Distinct from [`Item::section`], which is only a display heading. Two
    /// providers may share a heading, since nothing stops two plugin manifests
    /// carrying the same `title`, but their ids are unique. The filter pill bar
    /// keys on this, so every provider owns exactly one pill that filters to
    /// its own rows. That includes every plugin.
    pub provider: Option<String>,
    /// [`Item::id`] of the row this one hangs beneath, for rows that are a
    /// detail of another rather than a peer of it.
    ///
    /// An application's `[Desktop Action …]` groups are the case this exists
    /// for: "New Private Window" is a way of opening LibreWolf, not a
    /// separate application, and the list should say so. `crate::rank` pulls
    /// a child up to sit directly under its parent after scoring, and `view`
    /// draws it indented.
    ///
    /// A child whose parent did not survive the filter is still shown — if
    /// the query only matched the action, the action is what was meant — so
    /// this is a layout hint, never a lifetime dependency.
    pub parent: Option<String>,
    /// Ranking score, filled in by `crate::rank`. Higher sorts first.
    pub score: i64,
    /// What Enter does.
    pub action: Action,
    /// Extra actions offered by the Ctrl+K panel.
    pub alt_actions: Vec<(String, Action)>,
}

impl Item {
    /// A row with only the fields every provider must supply.
    pub fn new(id: impl Into<String>, title: impl Into<String>, action: Action) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            keywords: Vec::new(),
            subtitle: None,
            accessory: None,
            icon: None,
            section: None,
            provider: None,
            parent: None,
            score: 0,
            action,
            alt_actions: Vec::new(),
        }
    }

    #[must_use]
    pub fn subtitle(mut self, subtitle: impl Into<String>) -> Self {
        self.subtitle = Some(subtitle.into());
        self
    }

    /// Add search words the row answers to but never displays.
    #[must_use]
    pub fn keywords<I, S>(mut self, keywords: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.keywords.extend(keywords.into_iter().map(Into::into));
        self
    }

    #[must_use]
    pub fn accessory(mut self, accessory: impl Into<String>) -> Self {
        self.accessory = Some(accessory.into());
        self
    }

    #[must_use]
    pub fn icon(mut self, icon: Option<PathBuf>) -> Self {
        self.icon = icon;
        self
    }

    #[must_use]
    pub fn section(mut self, section: impl Into<String>) -> Self {
        self.section = Some(section.into());
        self
    }

    #[must_use]
    pub fn provider(mut self, provider: impl Into<String>) -> Self {
        self.provider = Some(provider.into());
        self
    }

    /// Hang this row beneath `parent`, the [`Item::id`] of another row.
    #[must_use]
    pub fn parent(mut self, parent: impl Into<String>) -> Self {
        self.parent = Some(parent.into());
        self
    }

    #[must_use]
    pub fn alt(mut self, label: impl Into<String>, action: Action) -> Self {
        self.alt_actions.push((label.into(), action));
        self
    }
}
