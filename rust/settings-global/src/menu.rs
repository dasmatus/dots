//! Menu model shared by the headless frontends (`dump`, `set`, `serve`): one
//! table owns both the field list and the dispatch, so the JSON emitted to
//! beamenu-canvas and the values `set`/`form.submit` writes back cannot drift
//! apart.

use serde::Serialize;
use serde_json::{Map, Value};

use crate::settings::{
    validate_git_email, validate_git_name, validate_git_signing_key, validate_hostname,
    validate_ollama_endpoint, validate_proton_email, validate_timezone, Settings,
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
    /// A validated integer value at `key`, bounded to `[min, max]` in steps
    /// of `step` — the range a slider renders against. `validate` is an
    /// extra hook for rules the range alone does not express; pass
    /// `|_| Ok(())` when the range is the whole rule.
    EditInt {
        key: &'static str,
        prompt: &'static str,
        min: i64,
        max: i64,
        step: i64,
        validate: fn(i64) -> Result<(), String>,
    },
    /// A string value at `key` constrained to one of `options` — a
    /// dropdown. `options` reaches the dump payload too, so the front end
    /// never keeps a second copy of the choices that could drift out of
    /// sync with this one.
    Select {
        key: &'static str,
        prompt: &'static str,
        options: &'static [&'static str],
    },
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
            Action::EditStr { key, .. }
            | Action::Toggle { key }
            | Action::EditInt { key, .. }
            | Action::Select { key, .. } => key,
        }
    }

    /// The field type as the dump/render JSON spells it.
    #[must_use]
    pub fn kind(&self) -> &'static str {
        match &self.action {
            Action::EditStr { .. } => "text",
            Action::Toggle { .. } => "checkbox",
            Action::EditInt { .. } => "number",
            Action::Select { .. } => "select",
        }
    }

    /// The row's current value, typed to match `kind()`. A missing or
    /// malformed stored value falls back to that type's zero value (`""`,
    /// `false`, `0`) — the same convention `get_str`/`get_bool`/`get_int`
    /// document individually.
    #[must_use]
    pub fn value_json(&self, settings: &Settings) -> Value {
        match &self.action {
            Action::EditStr { key, .. } | Action::Select { key, .. } => {
                Value::String(settings.get_str(key).unwrap_or_default())
            }
            Action::Toggle { key } => Value::Bool(settings.get_bool(key).unwrap_or_default()),
            Action::EditInt { key, .. } => Value::from(settings.get_int(key).unwrap_or_default()),
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
    Item {
        label: "Timezone",
        action: Action::EditStr {
            key: "timezone",
            prompt: "Timezone",
            validate: validate_timezone,
        },
    },
    Item {
        label: "Desktop",
        action: Action::Select {
            key: "desktop",
            prompt: "Desktop",
            options: &["hyprland", "none"],
        },
    },
    Item {
        label: "Window gaps (inner)",
        action: Action::EditInt {
            key: "wmGapsIn",
            prompt: "Window gaps (inner)",
            min: 0,
            max: 50,
            step: 1,
            validate: |_| Ok(()),
        },
    },
    Item {
        label: "Window gaps (outer)",
        action: Action::EditInt {
            key: "wmGapsOut",
            prompt: "Window gaps (outer)",
            min: 0,
            max: 100,
            step: 1,
            validate: |_| Ok(()),
        },
    },
    Item {
        label: "Window border size",
        action: Action::EditInt {
            key: "wmBorderSize",
            prompt: "Window border size",
            min: 0,
            max: 10,
            step: 1,
            validate: |_| Ok(()),
        },
    },
    Item {
        label: "Focus follows mouse",
        action: Action::Toggle {
            key: "wmFollowMouse",
        },
    },
    Item {
        label: "Window animations",
        action: Action::Toggle {
            key: "wmAnimations",
        },
    },
    Item {
        label: "Window layout",
        action: Action::Select {
            key: "wmLayout",
            prompt: "Window layout",
            options: &["dwindle", "master"],
        },
    },
    Item {
        label: "Ollama endpoint",
        action: Action::EditStr {
            key: "aiOllamaEndpoint",
            prompt: "Ollama endpoint",
            validate: validate_ollama_endpoint,
        },
    },
    Item {
        label: "Git signing key",
        action: Action::EditStr {
            key: "gitSigningKey",
            prompt: "Git signing key",
            validate: validate_git_signing_key,
        },
    },
];

/// One row of `global-settings dump`'s JSON array. `min`/`max`/`step` are
/// only present for `EditInt` rows (so a QML slider can bound itself
/// instead of hardcoding limits) and `options` only for `Select` rows;
/// every other combination serializes to no field at all rather than `null`.
#[derive(Serialize)]
pub struct DumpItem {
    pub key: &'static str,
    pub label: &'static str,
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub value: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<&'static [&'static str]>,
}

/// `global-settings dump`'s payload: one entry per item, current values
/// included. `EditStr`/`EditInt`/`Select` carry a prompt; `Toggle` has none.
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
                Action::EditStr { prompt, .. }
                | Action::EditInt { prompt, .. }
                | Action::Select { prompt, .. } => Some(*prompt),
                Action::Toggle { .. } => None,
            },
            min: match &item.action {
                Action::EditInt { min, .. } => Some(*min),
                _ => None,
            },
            max: match &item.action {
                Action::EditInt { max, .. } => Some(*max),
                _ => None,
            },
            step: match &item.action {
                Action::EditInt { step, .. } => Some(*step),
                _ => None,
            },
            options: match &item.action {
                Action::Select { options, .. } => Some(*options),
                _ => None,
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
    Int(i64),
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
            Action::EditInt {
                min, max, validate, ..
            } => {
                let n = new_value
                    .as_i64()
                    .ok_or_else(|| format!("{key}: expected an integer value"))?;
                if settings.get_int(key) == Some(n) {
                    continue;
                }
                if n < *min || n > *max {
                    return Err(format!("{key}: must be between {min} and {max}, got {n}"));
                }
                validate(n)?;
                edits.push((key, Edit::Int(n)));
            }
            Action::Select { options, .. } => {
                let s = new_value
                    .as_str()
                    .ok_or_else(|| format!("{key}: expected a string value"))?;
                if settings.get_str(key).as_deref() == Some(s) {
                    continue;
                }
                if !options.contains(&s) {
                    return Err(format!("{key}: must be one of {options:?}, got `{s}`"));
                }
                edits.push((key, Edit::Str(s.to_string())));
            }
        }
    }
    let changed = !edits.is_empty();
    for (key, edit) in edits {
        match edit {
            Edit::Str(s) => settings.set_str(key, &s),
            Edit::Bool(b) => settings.set_bool(key, b),
            Edit::Int(n) => settings.set_int(key, n),
        }
    }
    Ok(changed)
}
