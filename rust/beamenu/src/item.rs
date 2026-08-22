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
    /// Descend into another provider's list instead of closing the launcher.
    Push { provider: String, query: String },
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
    /// Primary text. The only field the filter matches against.
    pub title: String,
    /// Muted text drawn after the title.
    pub subtitle: Option<String>,
    /// Right-aligned trailing text.
    pub accessory: Option<String>,
    /// Path to an icon file; SVG and PNG render, anything else is ignored.
    pub icon: Option<PathBuf>,
    /// Heading this row is grouped under.
    pub section: Option<String>,
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
            subtitle: None,
            accessory: None,
            icon: None,
            section: None,
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
    pub fn alt(mut self, label: impl Into<String>, action: Action) -> Self {
        self.alt_actions.push((label.into(), action));
        self
    }
}
