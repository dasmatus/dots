//! JSON-RPC 2.0 envelope handling for the `ui: "rpc"` view mode (binding
//! protocol — see the task brief). Messages are newline-delimited JSON on the
//! child worker's stdin/stdout; each line is one JSON-RPC 2.0 object.
//!
//! The canvas only ever plays two roles here: it reads *notifications* the
//! worker pushes (`ui.render`, `log.append`), and it reads *responses* to the
//! one request type it sends (`form.submit`). It never expects a request
//! from the worker, so a line carrying both `method` and `id` is rejected as
//! a protocol violation rather than guessed at.

use std::collections::HashMap;

use serde_json::{json, Value};

const JSONRPC_VERSION: &str = "2.0";

/// A parsed line from the worker's stdout.
#[derive(Debug, Clone, PartialEq)]
pub enum IncomingMessage {
    Notification { method: String, params: Value },
    Response(RpcResponse),
}

/// A reply to a request the canvas sent (currently only `form.submit`).
#[derive(Debug, Clone, PartialEq)]
pub struct RpcResponse {
    pub id: i64,
    pub outcome: Result<Value, RpcErrorPayload>,
}

/// The binding error shape is just `{"message": "…"}` — no `code`, unlike
/// strict JSON-RPC 2.0.
#[derive(Debug, Clone, PartialEq)]
pub struct RpcErrorPayload {
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum RpcParseError {
    InvalidJson(String),
    NotAnObject,
    UnsupportedVersion(String),
    RequestFromWorker,
    MalformedResponse(String),
}

impl std::fmt::Display for RpcParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidJson(err) => write!(f, "invalid JSON: {err}"),
            Self::NotAnObject => write!(f, "JSON-RPC message must be an object"),
            Self::UnsupportedVersion(version) => {
                write!(f, "unsupported jsonrpc version '{version}'")
            }
            Self::RequestFromWorker => write!(
                f,
                "worker sent a request; only notifications and form.submit responses are accepted"
            ),
            Self::MalformedResponse(reason) => {
                write!(f, "malformed JSON-RPC response: {reason}")
            }
        }
    }
}

impl std::error::Error for RpcParseError {}

/// Parse one line of the worker's stdout into a notification or a response.
///
/// # Errors
/// Fails when the line isn't valid JSON, isn't a JSON object, names an
/// unsupported `jsonrpc` version, carries both `method` and `id` (a request,
/// which this protocol direction never allows), or is a response missing
/// `id` or carrying neither/both of `result`/`error`.
pub fn parse_incoming(line: &str) -> Result<IncomingMessage, RpcParseError> {
    let value: Value =
        serde_json::from_str(line).map_err(|err| RpcParseError::InvalidJson(err.to_string()))?;
    let Value::Object(map) = value else {
        return Err(RpcParseError::NotAnObject);
    };

    if let Some(version) = map.get("jsonrpc") {
        if version.as_str() != Some(JSONRPC_VERSION) {
            // `Value::to_string()` renders JSON text (a string value comes
            // back double-quoted); `as_str()` gives the bare string when
            // there is one, falling back to the JSON form only for a
            // non-string `jsonrpc` field.
            let reported = version
                .as_str()
                .map_or_else(|| version.to_string(), ToString::to_string);
            return Err(RpcParseError::UnsupportedVersion(reported));
        }
    }

    let has_method = map.contains_key("method");
    let has_id = map.contains_key("id");

    if has_method {
        if has_id {
            return Err(RpcParseError::RequestFromWorker);
        }
        let method = map
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let params = map.get("params").cloned().unwrap_or(Value::Null);
        return Ok(IncomingMessage::Notification { method, params });
    }

    let id = match map.get("id") {
        Some(Value::Number(number)) => number
            .as_i64()
            .ok_or_else(|| RpcParseError::MalformedResponse("id is not an integer".into()))?,
        Some(_) => {
            return Err(RpcParseError::MalformedResponse(
                "id must be a number".into(),
            ))
        }
        None => {
            return Err(RpcParseError::MalformedResponse(
                "response missing id".into(),
            ))
        }
    };

    let outcome = match (map.get("result"), map.get("error")) {
        (Some(result), None) => Ok(result.clone()),
        (None, Some(error)) => {
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcParseError::MalformedResponse("error missing message".into()))?
                .to_string();
            Err(RpcErrorPayload { message })
        }
        _ => {
            return Err(RpcParseError::MalformedResponse(
                "response needs exactly one of result/error".into(),
            ))
        }
    };

    Ok(IncomingMessage::Response(RpcResponse { id, outcome }))
}

/// Build the `form.submit` request the canvas sends to the worker's stdin.
///
/// `values` uses [`Value`] because a form field's answer can be a string
/// (text/password/dropdown) or a bool (checkbox).
#[must_use]
pub fn form_submit_request(id: i64, values: &HashMap<String, Value>) -> Value {
    json!({
        "jsonrpc": JSONRPC_VERSION,
        "id": id,
        "method": "form.submit",
        "params": { "values": values },
    })
}

/// The notification the canvas sends before it closes.
#[must_use]
pub fn shutdown_notification() -> Value {
    json!({
        "jsonrpc": JSONRPC_VERSION,
        "method": "shutdown",
    })
}
