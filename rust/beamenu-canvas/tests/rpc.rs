//! JSON-RPC 2.0 envelope parsing (worker -> canvas notifications and
//! responses) and outgoing message serialization (canvas -> worker
//! `form.submit` requests and the `shutdown` notification), including form
//! value serialization for mixed field types.

use std::collections::HashMap;

use beamenu_canvas::rpc::{
    form_submit_request, parse_incoming, shutdown_notification, IncomingMessage, RpcParseError,
};
use serde_json::{json, Value};

#[test]
fn parses_ui_render_notification() {
    let line = r#"{"jsonrpc":"2.0","method":"ui.render","params":{"tree":{"type":"log"}}}"#;
    let message = parse_incoming(line).expect("valid notification");
    let IncomingMessage::Notification { method, params } = message else {
        panic!("expected a notification");
    };
    assert_eq!(method, "ui.render");
    assert_eq!(params["tree"]["type"], "log");
}

#[test]
fn parses_log_append_notification() {
    let line = r#"{"jsonrpc":"2.0","method":"log.append","params":{"text":"hello"}}"#;
    let message = parse_incoming(line).expect("valid notification");
    let IncomingMessage::Notification { method, params } = message else {
        panic!("expected a notification");
    };
    assert_eq!(method, "log.append");
    assert_eq!(params["text"], "hello");
}

#[test]
fn notification_without_jsonrpc_field_is_accepted() {
    // Some workers may omit the version field; we only reject a WRONG one.
    let line = r#"{"method":"log.append","params":{"text":"hi"}}"#;
    assert!(parse_incoming(line).is_ok());
}

#[test]
fn rejects_wrong_jsonrpc_version() {
    let line = r#"{"jsonrpc":"1.0","method":"log.append","params":{}}"#;
    let err = parse_incoming(line).expect_err("wrong version rejected");
    assert_eq!(err, RpcParseError::UnsupportedVersion("1.0".to_string()));
}

#[test]
fn rejects_request_from_worker() {
    // Carries both `method` and `id` — a request, which this protocol
    // direction never allows from the worker.
    let line = r#"{"jsonrpc":"2.0","id":1,"method":"ui.render","params":{}}"#;
    let err = parse_incoming(line).expect_err("request from worker rejected");
    assert_eq!(err, RpcParseError::RequestFromWorker);
}

#[test]
fn rejects_invalid_json() {
    let err = parse_incoming("{ not json").expect_err("invalid json rejected");
    assert!(matches!(err, RpcParseError::InvalidJson(_)));
}

#[test]
fn rejects_non_object_message() {
    let err = parse_incoming("42").expect_err("non-object rejected");
    assert_eq!(err, RpcParseError::NotAnObject);
}

#[test]
fn parses_successful_form_submit_response() {
    let line = r#"{"jsonrpc":"2.0","id":7,"result":{}}"#;
    let message = parse_incoming(line).expect("valid response");
    let IncomingMessage::Response(response) = message else {
        panic!("expected a response");
    };
    assert_eq!(response.id, 7);
    assert_eq!(response.outcome, Ok(json!({})));
}

#[test]
fn parses_error_form_submit_response() {
    let line = r#"{"jsonrpc":"2.0","id":7,"error":{"message":"bad password"}}"#;
    let message = parse_incoming(line).expect("valid error response");
    let IncomingMessage::Response(response) = message else {
        panic!("expected a response");
    };
    assert_eq!(response.id, 7);
    let err = response.outcome.expect_err("error outcome");
    assert_eq!(err.message, "bad password");
}

#[test]
fn rejects_response_missing_id() {
    let line = r#"{"jsonrpc":"2.0","result":{}}"#;
    assert!(matches!(
        parse_incoming(line),
        Err(RpcParseError::MalformedResponse(_))
    ));
}

#[test]
fn rejects_response_with_both_result_and_error() {
    let line = r#"{"jsonrpc":"2.0","id":1,"result":{},"error":{"message":"x"}}"#;
    assert!(matches!(
        parse_incoming(line),
        Err(RpcParseError::MalformedResponse(_))
    ));
}

#[test]
fn rejects_response_with_neither_result_nor_error() {
    let line = r#"{"jsonrpc":"2.0","id":1}"#;
    assert!(matches!(
        parse_incoming(line),
        Err(RpcParseError::MalformedResponse(_))
    ));
}

#[test]
fn form_submit_request_serializes_mixed_value_types() {
    let mut values: HashMap<String, Value> = HashMap::new();
    values.insert("username".to_string(), json!("alice"));
    values.insert("remember".to_string(), json!(true));
    values.insert("attempts".to_string(), json!(3));

    let request = form_submit_request(42, &values);

    assert_eq!(request["jsonrpc"], "2.0");
    assert_eq!(request["id"], 42);
    assert_eq!(request["method"], "form.submit");
    assert_eq!(request["params"]["values"]["username"], "alice");
    assert_eq!(request["params"]["values"]["remember"], true);
    assert_eq!(request["params"]["values"]["attempts"], 3);
}

#[test]
fn form_submit_request_with_empty_values_still_has_values_object() {
    let values: HashMap<String, Value> = HashMap::new();
    let request = form_submit_request(1, &values);
    assert_eq!(request["params"]["values"], json!({}));
}

#[test]
fn shutdown_notification_has_no_id() {
    let notification = shutdown_notification();
    assert_eq!(notification["jsonrpc"], "2.0");
    assert_eq!(notification["method"], "shutdown");
    assert!(notification.get("id").is_none());
}
