//! Menu model shared by the rofi frontend: one table owns both the row
//! labels and the dispatch, so the displayed list and the actions cannot
//! drift apart.

use crate::settings::{validate_git_email, validate_git_name, validate_hostname, Settings};

/// What selecting a row does.
pub enum Action {
    /// Prompt for a validated string value for `key`.
    EditStr {
        key: &'static str,
        prompt: &'static str,
        validate: fn(&str) -> Result<(), String>,
    },
    /// Flip the boolean at `key`.
    Toggle { key: &'static str },
    /// Leave the menu.
    Exit,
}

/// One menu row: display label plus its action.
pub struct Item {
    pub label: &'static str,
    pub action: Action,
}

/// The menu, top to bottom. `Exit` must stay last.
pub const ITEMS: &[Item] = &[
    Item {
        label: "Git name",
        action: Action::EditStr {
            key: "gitName",
            prompt: "Git name",
            validate: validate_git_name,
        },
    },
    Item {
        label: "Git email",
        action: Action::EditStr {
            key: "gitEmail",
            prompt: "Git email",
            validate: validate_git_email,
        },
    },
    Item {
        label: "Hostname",
        action: Action::EditStr {
            key: "hostname",
            prompt: "Hostname",
            validate: validate_hostname,
        },
    },
    Item {
        label: "AI: Ollama",
        action: Action::Toggle { key: "aiOllama" },
    },
    Item {
        label: "AI: Claude Code",
        action: Action::Toggle { key: "aiClaude" },
    },
    Item {
        label: "AI: Codex",
        action: Action::Toggle { key: "aiCodex" },
    },
    Item {
        label: "Exit",
        action: Action::Exit,
    },
];

/// Expand an optional theme name/path (from `GLOBAL_SETTINGS_ROFI_THEME`)
/// into the rofi `-theme` flag pair; empty/absent means rofi's default.
#[must_use]
pub fn theme_args(theme: Option<String>) -> Vec<String> {
    match theme {
        Some(theme) if !theme.is_empty() => vec!["-theme".into(), theme],
        _ => Vec::new(),
    }
}

/// Render one display row per item, current values included.
#[must_use]
pub fn rows(settings: &Settings) -> Vec<String> {
    ITEMS
        .iter()
        .map(|item| match &item.action {
            Action::EditStr { key, .. } => {
                let value = settings.get_str(key).unwrap_or_default();
                format!("{}: {value}", item.label)
            }
            Action::Toggle { key } => {
                let state = if settings.get_bool(key).unwrap_or_default() {
                    "on"
                } else {
                    "off"
                };
                format!("{}: {state}", item.label)
            }
            Action::Exit => item.label.to_string(),
        })
        .collect()
}
