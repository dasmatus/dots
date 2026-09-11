//! Pure-function tests for `rpc::parse_line` and the notification/response
//! builders, the framing edge cases that are awkward to provoke by driving
//! a live subprocess (malformed JSON, missing id, unknown methods).

use global_settings::rpc::{self, Incoming};
use global_settings::settings::Settings;
use serde_json::json;

#[test]
fn parses_shutdown_notification() {
    assert!(matches!(
        rpc::parse_line(r#"{"jsonrpc":"2.0","method":"shutdown"}"#).unwrap(),
        Incoming::Shutdown
    ));
}

#[test]
fn parses_form_submit_request() {
    let msg = rpc::parse_line(
        r#"{"jsonrpc":"2.0","id":3,"method":"form.submit","params":{"values":{"hostname":"x"}}}"#,
    )
    .unwrap();
    let Incoming::FormSubmit { id, values } = msg else {
        panic!("expected FormSubmit");
    };
    assert_eq!(id, json!(3));
    assert_eq!(values.get("hostname"), Some(&json!("x")));
}

#[test]
fn rejects_malformed_json() {
    let err = rpc::parse_line("not json").unwrap_err();
    assert!(!err.is_empty());
}

#[test]
fn form_submit_without_id_is_rejected() {
    let err = rpc::parse_line(r#"{"jsonrpc":"2.0","method":"form.submit","params":{"values":{}}}"#)
        .unwrap_err();
    assert!(err.contains("id"), "{err}");
}

#[test]
fn unknown_method_with_id_is_reported() {
    let msg = rpc::parse_line(r#"{"jsonrpc":"2.0","id":9,"method":"nonsense"}"#).unwrap();
    let Incoming::Unknown { id, method } = msg else {
        panic!("expected Unknown");
    };
    assert_eq!(id, Some(json!(9)));
    assert_eq!(method, "nonsense");
}

#[test]
fn unknown_notification_has_no_id() {
    let msg = rpc::parse_line(r#"{"jsonrpc":"2.0","method":"log.append","params":{"text":"x"}}"#)
        .unwrap();
    let Incoming::Unknown { id, method } = msg else {
        panic!("expected Unknown");
    };
    assert_eq!(id, None);
    assert_eq!(method, "log.append");
}

#[test]
fn render_notification_has_the_documented_envelope() {
    let s = Settings::parse("{\n  hostname = \"box\";\n}\n").unwrap();
    let line = rpc::render_notification(&s);
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["jsonrpc"], "2.0");
    assert_eq!(v["method"], "ui.render");
    assert_eq!(v["params"]["tree"]["type"], "form");
    assert_eq!(v["params"]["tree"]["submit_label"], "Save");
    assert!(v.get("id").is_none(), "a notification must not carry an id");
}

#[test]
fn result_and_error_responses_carry_the_request_id() {
    let id = json!(5);
    let ok: serde_json::Value = serde_json::from_str(&rpc::result_response(&id)).unwrap();
    assert_eq!(ok["id"], 5);
    assert_eq!(ok["result"], json!({}));

    let err: serde_json::Value = serde_json::from_str(&rpc::error_response(&id, "bad")).unwrap();
    assert_eq!(err["id"], 5);
    assert_eq!(err["error"]["message"], "bad");
}
