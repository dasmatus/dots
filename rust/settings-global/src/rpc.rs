//! JSON-RPC 2.0 framing for `global-settings serve`'s stdio conversation with
//! the beamenu-canvas sidecar (protocol v1, binding across both crates): one
//! JSON object per line. Only the subset `serve` needs is implemented.
//! `ui.render` out, `form.submit`/`shutdown` in.

use serde::Deserialize;
use serde_json::{json, Map, Value};

use crate::menu::form_fields;
use crate::settings::Settings;

/// One decoded line from the canvas.
#[derive(Debug)]
pub enum Incoming {
    /// `form.submit {"values": {...}}`, a request, so it carries `id` and
    /// expects a `result`/`error` response.
    FormSubmit {
        id: Value,
        values: Map<String, Value>,
    },
    /// `shutdown`, a notification; `serve` exits 0 on receipt.
    Shutdown,
    /// A request for a method this worker does not implement; `id` is
    /// `Some` when a response is owed (it was a request, not a notification).
    Unknown { id: Option<Value>, method: String },
}

/// The raw JSON-RPC envelope shape, before we look at `method`.
#[derive(Deserialize)]
struct Envelope {
    #[serde(default)]
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
struct FormSubmitParams {
    #[serde(default)]
    values: Map<String, Value>,
}

/// Decode one line of the protocol.
///
/// # Errors
/// Returns a message describing why the line is not a valid envelope for
/// this worker (malformed JSON, or a `form.submit` missing `id`/`values`).
pub fn parse_line(line: &str) -> Result<Incoming, String> {
    let envelope: Envelope =
        serde_json::from_str(line).map_err(|e| format!("malformed JSON-RPC line: {e}"))?;
    match envelope.method.as_str() {
        "shutdown" => Ok(Incoming::Shutdown),
        "form.submit" => {
            let id = envelope
                .id
                .ok_or_else(|| "form.submit: request needs an id".to_string())?;
            let params: FormSubmitParams = serde_json::from_value(envelope.params)
                .map_err(|e| format!("form.submit: bad params: {e}"))?;
            Ok(Incoming::FormSubmit {
                id,
                values: params.values,
            })
        }
        other => Ok(Incoming::Unknown {
            id: envelope.id,
            method: other.to_string(),
        }),
    }
}

/// `ui.render {"tree": {"type":"form", ...}}`, built fresh from `settings`.
#[must_use]
pub fn render_notification(settings: &Settings) -> String {
    json!({
        "jsonrpc": "2.0",
        "method": "ui.render",
        "params": {
            "tree": {
                "type": "form",
                "fields": form_fields(settings),
                "submit_label": "Save",
            },
        },
    })
    .to_string()
}

/// A `form.submit` success response: `{"id", "result": {}}`.
#[must_use]
pub fn result_response(id: &Value) -> String {
    json!({ "jsonrpc": "2.0", "id": id, "result": {} }).to_string()
}

/// A `form.submit` (or unknown-method) failure response.
#[must_use]
pub fn error_response(id: &Value, message: &str) -> String {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "message": message } }).to_string()
}
