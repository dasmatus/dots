//! The JSON-RPC side of the plugin worker.
//!
//! Newline-delimited JSON-RPC 2.0 over stdio, which is what a plugin manifest's
//! `ui: "rpc"` view mode gets. The traffic is asymmetric and deliberately
//! small: this end pushes `ui.render` and `log.append` notifications, and the
//! canvas sends exactly one request back, `form.submit`. Nothing here ever
//! sends a request, because the canvas rejects one as a protocol violation.

use serde_json::{json, Map, Value};

use crate::eval::{AngleMode, Radix};

const VERSION: &str = "2.0";

/// A message read from the canvas.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// The user pressed the form's submit button.
    FormSubmit { id: i64, values: Map<String, Value> },
    /// Anything else the canvas may send later. Ignored rather than fatal, so
    /// a newer canvas talking to an older worker degrades instead of dying.
    Other,
}

/// Parse one line of the canvas's output.
///
/// # Errors
/// Fails when the line is not a JSON object, or names a `jsonrpc` version this
/// does not speak.
pub fn parse_incoming(line: &str) -> Result<Incoming, String> {
    let value: Value = serde_json::from_str(line).map_err(|err| format!("invalid JSON: {err}"))?;
    let Value::Object(map) = value else {
        return Err("JSON-RPC message must be an object".into());
    };

    match map.get("jsonrpc").and_then(Value::as_str) {
        Some(VERSION) => {}
        Some(other) => return Err(format!("unsupported jsonrpc version '{other}'")),
        None => return Err("missing jsonrpc version".into()),
    }

    if map.get("method").and_then(Value::as_str) != Some("form.submit") {
        return Ok(Incoming::Other);
    }

    let Some(id) = map.get("id").and_then(Value::as_i64) else {
        return Err("form.submit without an id".into());
    };

    let values = map
        .get("params")
        .and_then(|params| params.get("values"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();

    Ok(Incoming::FormSubmit { id, values })
}

/// Wrap a component tree in the `ui.render` notification.
#[must_use]
pub fn render(tree: &Value) -> Value {
    json!({ "jsonrpc": VERSION, "method": "ui.render", "params": { "tree": tree } })
}

/// Append one line to the canvas's log pane.
#[must_use]
pub fn log_line(text: &str) -> Value {
    json!({ "jsonrpc": VERSION, "method": "log.append", "params": { "text": text } })
}

/// Answer a `form.submit` request.
#[must_use]
pub fn ok_response(id: i64, result: &Value) -> Value {
    json!({ "jsonrpc": VERSION, "id": id, "result": result })
}

/// Refuse a `form.submit` request. The canvas reads `{"message": ...}`, with no
/// `code`, so this is not quite strict JSON-RPC.
#[must_use]
pub fn error_response(id: i64, message: &str) -> Value {
    json!({ "jsonrpc": VERSION, "id": id, "error": { "message": message } })
}

impl AngleMode {
    /// The wire name used in the form's dropdown.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Radians => "radians",
            Self::Degrees => "degrees",
        }
    }

    /// Read a dropdown value back, falling back to radians.
    #[must_use]
    pub fn from_str_or_default(value: &str) -> Self {
        match value {
            "degrees" => Self::Degrees,
            _ => Self::Radians,
        }
    }
}

impl Radix {
    /// The wire name used in the form's dropdown.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Decimal => "decimal",
            Self::Hex => "hex",
            Self::Binary => "binary",
        }
    }

    /// Read a dropdown value back, falling back to decimal.
    #[must_use]
    pub fn from_str_or_default(value: &str) -> Self {
        match value {
            "hex" => Self::Hex,
            "binary" => Self::Binary,
            _ => Self::Decimal,
        }
    }
}

/// The calculator's form: an expression, how to read angles, and what base to
/// answer in.
///
/// `Component::Form` is the only input the canvas can draw, and its field types
/// are text, password, checkbox and dropdown. Angle mode and radix are both
/// dropdowns because they are three-way and two-way choices respectively, and a
/// checkbox cannot say "hex or binary or neither".
#[must_use]
pub fn calculator_form(expr: &str, angle: AngleMode, radix: Radix) -> Value {
    json!({
        "type": "form",
        "submit_label": "Evaluate",
        "fields": [
            {
                "key": "expr",
                "label": "Expression",
                "type": "text",
                "value": expr,
            },
            {
                "key": "angle",
                "label": "Angles",
                "type": "dropdown",
                "value": angle.as_str(),
                "options": ["radians", "degrees"],
            },
            {
                "key": "radix",
                "label": "Base",
                "type": "dropdown",
                "value": radix.as_str(),
                "options": ["decimal", "hex", "binary"],
            },
        ],
    })
}

/// The pane shown after a successful evaluation.
#[must_use]
pub fn result_detail(expr: &str, rendered: &str) -> Value {
    json!({
        "type": "detail",
        "markdown": format!("## {rendered}\n\n`{expr}`"),
    })
}

/// The pane shown when an expression could not be evaluated.
#[must_use]
pub fn error_detail(expr: &str, message: &str) -> Value {
    json!({
        "type": "detail",
        "markdown": format!("## Cannot evaluate\n\n`{expr}`\n\n{message}"),
    })
}
