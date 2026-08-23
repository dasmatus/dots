//! Dispatch from a parsed `ui.render`/`log.append` notification to a
//! `CanvasEvent`, tying `rpc::parse_incoming` to `component::Component`
//! validation.

use beamenu_canvas::component::Component;
use beamenu_canvas::dispatch::{dispatch_notification, CanvasEvent};
use beamenu_canvas::rpc::{parse_incoming, IncomingMessage};
use serde_json::json;

fn notification_params(line: &str) -> serde_json::Value {
    match parse_incoming(line).expect("valid notification") {
        IncomingMessage::Notification { params, .. } => params,
        IncomingMessage::Response(_) => panic!("expected a notification"),
    }
}

#[test]
fn ui_render_with_valid_tree_dispatches_to_render() {
    let line = r#"{"jsonrpc":"2.0","method":"ui.render","params":{"tree":{"type":"detail","markdown":"hi"}}}"#;
    let params = notification_params(line);
    let event = dispatch_notification("ui.render", &params);
    assert_eq!(
        event,
        CanvasEvent::Render(Component::Detail {
            markdown: "hi".to_string()
        })
    );
}

#[test]
fn ui_render_with_invalid_tree_dispatches_to_error() {
    let params = json!({"tree": {"type": "html", "html": "<script></script>"}});
    let event = dispatch_notification("ui.render", &params);
    assert!(matches!(event, CanvasEvent::Error(_)));
}

#[test]
fn ui_render_missing_tree_dispatches_to_error() {
    let event = dispatch_notification("ui.render", &json!({}));
    assert!(matches!(event, CanvasEvent::Error(_)));
}

#[test]
fn log_append_dispatches_to_log_append() {
    let params = json!({"text": "building..."});
    let event = dispatch_notification("log.append", &params);
    assert_eq!(event, CanvasEvent::LogAppend("building...".to_string()));
}

#[test]
fn log_append_missing_text_dispatches_to_error() {
    let event = dispatch_notification("log.append", &json!({}));
    assert!(matches!(event, CanvasEvent::Error(_)));
}

#[test]
fn unknown_method_dispatches_to_error() {
    let event = dispatch_notification("wizard.summon", &json!({}));
    let CanvasEvent::Error(message) = event else {
        panic!("expected an error event");
    };
    assert!(message.contains("wizard.summon"));
}
