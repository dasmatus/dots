//! Menu model shared by the headless frontends (`dump`, `set`, `serve`): one
//! table owns both the field list and the dispatch, so the JSON emitted to
//! beamenu-canvas and the values `set`/`form.submit` writes back cannot drift
//! apart.

use serde::Serialize;
use serde_json::{Map, Value};

use crate::settings::{
    validate_git_email, validate_git_name, validate_hostname, validate_proton_email, Settings,
};

/// What editing a row does.
pub enum Action {
    /// A validated string value at `key`.
    EditStr {
        key: &'static str,
        prompt: &'static str,
        validate: fn(&str) -> Result<(), String>,
    },
    /// A boolean value at `key`.
    Toggle { key: &'static str },
}

/// One menu row: display label plus its action.
pub struct Item {
    pub label: &'static str,
    pub action: Action,
}

impl Item {
    /// The settings.nix key this row edits.
    #[must_use]
    pub fn key(&self) -> &'static str {
        match &self.action {
            Action::EditStr { key, .. } | Action::Toggle { key } => key,
        }
    }

    /// The field type as the dump/render JSON spells it.
    #[must_use]
    pub fn kind(&self) -> &'static str {
        match &self.action {
            Action::EditStr { .. } => "text",
            Action::Toggle { .. } => "checkbox",
        }
    }

    /// The row's current value, typed to match `kind()`.
    #[must_use]
    pub fn value_json(&self, settings: &Settings) -> Value {
        match &self.action {
            Action::EditStr { key, .. } => Value::String(settings.get_str(key).unwrap_or_default()),
            Action::Toggle { key } => Value::Bool(settings.get_bool(key).unwrap_or_default()),
        }
    }
}

/// The menu, top to bottom.
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
        label: "Proton email",
        action: Action::EditStr {
            key: "protonEmail",
            prompt: "Proton email",
            validate: validate_proton_email,
        },
    },
];

/// One row of `global-settings dump`'s JSON array.
#[derive(Serialize)]
pub struct DumpItem {
    pub key: &'static str,
    pub label: &'static str,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub value: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<&'static str>,
}

/// `global-settings dump`'s payload: one entry per item, current values
/// included. `EditStr` carries its prompt; `Toggle` has none.
#[must_use]
pub fn dump(settings: &Settings) -> Vec<DumpItem> {
    ITEMS
        .iter()
        .map(|item| DumpItem {
            key: item.key(),
            label: item.label,
            kind: item.kind(),
            value: item.value_json(settings),
            prompt: match &item.action {
                Action::EditStr { prompt, .. } => Some(*prompt),
                Action::Toggle { .. } => None,
            },
        })
        .collect()
}

/// One field of the `ui.render` form tree sent to beamenu-canvas.
#[derive(Serialize)]
pub struct FormField {
    pub key: &'static str,
    pub label: &'static str,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub value: Value,
}

/// The `serve` render tree's fields, current values included.
#[must_use]
pub fn form_fields(settings: &Settings) -> Vec<FormField> {
    ITEMS
        .iter()
        .map(|item| FormField {
            key: item.key(),
            label: item.label,
            kind: item.kind(),
            value: item.value_json(settings),
        })
        .collect()
}

/// A pending write, deferred until every changed field in a submission has
/// validated so a partially-invalid form applies nothing.
enum Edit {
    Str(String),
    Bool(bool),
}

/// Validate every field in `values` that differs from `settings`'s current
/// value, in `ITEMS` order (so "the first validation failure" is
/// deterministic), then apply all of them. Returns whether anything changed.
/// On the first invalid field `settings` is left untouched.
///
/// # Errors
/// Returns the validator's message (or a type-mismatch message) for the
/// first invalid field encountered.
pub fn apply_values(settings: &mut Settings, values: &Map<String, Value>) -> Result<bool, String> {
    let mut edits: Vec<(&'static str, Edit)> = Vec::new();
    for item in ITEMS {
        let key = item.key();
        let Some(new_value) = values.get(key) else {
            continue;
        };
        match &item.action {
            Action::EditStr { validate, .. } => {
                let s = new_value
                    .as_str()
                    .ok_or_else(|| format!("{key}: expected a string value"))?;
                if settings.get_str(key).as_deref() == Some(s) {
                    continue;
                }
                validate(s)?;
                edits.push((key, Edit::Str(s.to_string())));
            }
            Action::Toggle { .. } => {
                let b = new_value
                    .as_bool()
                    .ok_or_else(|| format!("{key}: expected a boolean value"))?;
                if settings.get_bool(key) == Some(b) {
                    continue;
                }
                edits.push((key, Edit::Bool(b)));
            }
        }
    }
    let changed = !edits.is_empty();
    for (key, edit) in edits {
        match edit {
            Edit::Str(s) => settings.set_str(key, &s),
            Edit::Bool(b) => settings.set_bool(key, b),
        }
    }
    Ok(changed)
}
