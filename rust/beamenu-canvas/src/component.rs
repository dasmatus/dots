//! The closed set of component trees a worker may hand the canvas over
//! `ui.render`.
//!
//! This is the enforcement point for "workers never supply CSS or HTML":
//! there is no variant carrying a raw HTML string, and `Detail::markdown`
//! only ever reaches the page through [`crate::markdown::render`], which
//! escapes everything it doesn't generate itself. Anything outside this
//! schema — an unknown `type`, a missing required field, an unknown form
//! field `type` — fails [`Component::validate`] with a message meant to be
//! rendered straight into the pane in place of the tree.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Component {
    Detail {
        markdown: String,
    },
    Log,
    Form {
        fields: Vec<FormField>,
        #[serde(default)]
        submit_label: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FormField {
    pub key: String,
    pub label: String,
    #[serde(rename = "type")]
    pub field_type: FieldType,
    #[serde(default)]
    pub value: Option<Value>,
    #[serde(default)]
    pub options: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FieldType {
    Text,
    Password,
    Checkbox,
    Dropdown,
}

/// A component tree failed validation. Carries a message fit to render
/// straight into the pane, in place of the tree that failed.
#[derive(Debug, Clone, PartialEq)]
pub struct ComponentError(pub String);

impl std::fmt::Display for ComponentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ComponentError {}

impl Component {
    /// Validate an arbitrary `ui.render` `tree` value.
    ///
    /// `serde`'s internally tagged enum already rejects anything outside
    /// `{detail, log, form}` and anything missing a required field — there is
    /// deliberately no variant that would accept, say,
    /// `{"type":"html","html":"..."}`.
    ///
    /// # Errors
    /// Fails when `value` doesn't match one of the three component shapes.
    pub fn validate(value: Value) -> Result<Self, ComponentError> {
        serde_json::from_value(value).map_err(|err| ComponentError(err.to_string()))
    }
}
