//! The row model and the actions a row can perform.
//!
//! An [`Item`] is what one line of the launcher shows and what happens when
//! you press Enter on it. Providers build these; `view` turns them into
//! `bm_item`s; [`Action`] is executed by `crate::dispatch`.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A change to the filesystem the launcher makes itself.
///
/// Named operations over paths rather than shell command strings, because a
/// filename is the one piece of user data most likely to contain a quote, a
/// space or a newline, and every one of these runs against a path somebody
/// picked out of a list. `crate::dispatch` runs them through `std::fs`, where
/// a path is an argument rather than a fragment of a command line, so there
/// is no quoting to get wrong.
///
/// Three of the five need a word before they can run; see [`Action::Prompt`]
/// for where that word comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileOp {
    /// Make a directory named by the prompt inside `parent`.
    NewFolder { parent: PathBuf },
    /// Rename `target` to the prompted name, in the directory it is already
    /// in. A name containing a path separator is refused rather than treated
    /// as a move; moving is [`FileOp::MoveTo`] and asks a different question.
    Rename { target: PathBuf },
    /// Move `target` into the prompted directory, keeping its name.
    MoveTo { target: PathBuf },
    /// Send `target` to the desktop's trash, where it can be got back.
    Trash { target: PathBuf },
    /// Remove `target` outright, recursively for a directory.
    Delete { target: PathBuf },
}

impl FileOp {
    /// The path this operates on, for a row that wants to name it.
    #[must_use]
    pub fn path(&self) -> &PathBuf {
        match self {
            Self::NewFolder { parent } => parent,
            Self::Rename { target }
            | Self::MoveTo { target }
            | Self::Trash { target }
            | Self::Delete { target } => target,
        }
    }

    /// Whether this needs a word typed before it can run.
    #[must_use]
    pub fn needs_argument(&self) -> bool {
        matches!(
            self,
            Self::NewFolder { .. } | Self::Rename { .. } | Self::MoveTo { .. }
        )
    }

    /// What to put on the search line when the prompt opens.
    ///
    /// Rename starts from the current name, because renaming is usually
    /// editing a name rather than replacing one. The other two start empty:
    /// there is no obvious new folder name, and prefilling a destination
    /// would only be a path to delete before typing the real one.
    #[must_use]
    pub fn initial(&self) -> String {
        match self {
            Self::Rename { target } => target
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
            _ => String::new(),
        }
    }
}

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
    /// Change the filesystem, with whatever [`FileOp::needs_argument`] asked
    /// for already supplied.
    File { op: FileOp, argument: String },
    /// Turn the search line into a text field for `op`, then run it.
    ///
    /// The launcher has one text field and it is already on screen, so a
    /// prompt reuses it rather than inventing a dialog: the frame that opens
    /// rebuilds its single row from whatever is typed, and Enter on that row
    /// runs the operation with it. Escape leaves without doing anything,
    /// which is what Escape does everywhere else here.
    Prompt { op: FileOp },
    /// Ask before running `action`.
    ///
    /// For the operations with nothing behind them. Trashing a file needs no
    /// confirmation because the file is still there; deleting one does,
    /// because a launcher is a place where a keystroke happens fast.
    Confirm { label: String, action: Box<Action> },
    /// Do nothing. Used by informational rows such as a calculator result
    /// that has already been copied.
    None,
}

/// What the preview pane draws for a row, when it is the highlighted one.
///
/// Deliberately a description of the thing rather than the thing itself. The
/// launcher rebuilds its list between keystrokes and must not stall on a
/// 40 MB image or a directory of ten thousand files, so nothing here is read,
/// decoded or measured on this side. The pane is a separate process and does
/// all of that in its own time; if it is slow, the keyboard is not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Preview {
    /// Whatever is at this path. The pane decides what it is from the name
    /// and from the bytes, since only it is allowed to look.
    File { path: PathBuf },
    /// Markdown the provider already holds, for a row whose preview is
    /// something it computed rather than something on disk.
    Markdown { body: String },
    /// A plugin command's own view, drawn in the pane instead of in a window
    /// of its own. Same three fields as [`Action::View`], and for the same
    /// reason: the pane re-reads the manifest and redoes the substitution.
    Command {
        manifest: PathBuf,
        command: String,
        query: String,
    },
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
    /// What the preview pane draws while this row is highlighted.
    ///
    /// `None` is the normal case and means the pane goes away for this row.
    /// A row only earns a preview when there is something to see: a file, a
    /// rendered document, a plugin's own view. Giving every row a placeholder
    /// pane would be worse than having none, since the panel would then keep
    /// a third of its width reserved for a shrug.
    pub preview: Option<Preview>,
    /// Rows for the strip under the preview, in order.
    ///
    /// The pane draws these as label/value pairs. Empty means no strip, and
    /// the preview gets that height back.
    ///
    /// Kept beside [`Item::preview`] rather than inside it because the two
    /// answer different questions. The preview is what the thing looks like
    /// and only the pane can produce it; the metadata is what the provider
    /// already knew when it built the row (a size it stat'd, a MIME type it
    /// resolved) and would be wasteful to make the pane rediscover.
    pub metadata: Vec<(String, String)>,
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
            preview: None,
            metadata: Vec::new(),
        }
    }

    /// Give this row a preview pane.
    #[must_use]
    pub fn preview(mut self, preview: Preview) -> Self {
        self.preview = Some(preview);
        self
    }

    /// Append one label/value row to the strip under the preview.
    #[must_use]
    pub fn meta(mut self, label: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.push((label.into(), value.into()));
        self
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
