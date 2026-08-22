//! Turns an incoming `ui.render`/`log.append` notification into a
//! [`CanvasEvent`] the GTK side can act on, validating any [`Component`]
//! tree along the way.

use serde_json::Value;

use crate::component::{Component, ComponentError};

/// Something the GTK side should do in response to a worker notification.
#[derive(Debug, Clone, PartialEq)]
pub enum CanvasEvent {
    Render(Component),
    LogAppend(String),
    /// Rendered straight into the pane rather than crashing the canvas —
    /// covers both a malformed `Component` tree and an unrecognized method.
    Error(String),
}

/// Dispatch one `worker → canvas` notification.
#[must_use]
pub fn dispatch_notification(method: &str, params: &Value) -> CanvasEvent {
    match method {
        "ui.render" => match params.get("tree") {
            Some(tree) => match Component::validate(tree.clone()) {
                Ok(component) => CanvasEvent::Render(component),
                Err(ComponentError(message)) => CanvasEvent::Error(message),
            },
            None => CanvasEvent::Error("ui.render notification is missing 'tree'".into()),
        },
        "log.append" => match params.get("text").and_then(Value::as_str) {
            Some(text) => CanvasEvent::LogAppend(text.to_string()),
            None => CanvasEvent::Error("log.append notification is missing 'text'".into()),
        },
        other => CanvasEvent::Error(format!("unknown notification method '{other}'")),
    }
}
