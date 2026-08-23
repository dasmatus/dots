//! The wire format, checked against what beamenu-canvas actually parses.
//!
//! The shapes asserted here mirror `rust/beamenu-canvas/src/component.rs`
//! (`Component`, `FormField`, `FieldType`) and `src/rpc.rs`. They are asserted
//! literally rather than by round-tripping through the canvas's own types,
//! because depending on that crate would drag `GTK` and `WebKit` into this
//! test build. If the canvas's schema moves, these are the assertions that
//! should fail.

use beamenu_calc::eval::{AngleMode, Radix};
use beamenu_calc::rpc::{
    calculator_form, error_detail, error_response, log_line, ok_response, parse_incoming, render,
    result_detail, Incoming,
};
use serde_json::{json, Value};

// --- reading the canvas ---

#[test]
fn a_form_submit_carries_its_id_and_field_values() {
    let line =
        r#"{"jsonrpc":"2.0","id":7,"method":"form.submit","params":{"values":{"expr":"1+1"}}}"#;

    match parse_incoming(line).expect("a parsed message") {
        Incoming::FormSubmit { id, values } => {
            assert_eq!(id, 7);
            assert_eq!(values.get("expr").and_then(Value::as_str), Some("1+1"));
        }
        Incoming::Other => panic!("expected a form.submit"),
    }
}

#[test]
fn a_form_submit_with_no_values_still_parses() {
    let line = r#"{"jsonrpc":"2.0","id":1,"method":"form.submit"}"#;

    match parse_incoming(line).expect("a parsed message") {
        Incoming::FormSubmit { id, values } => {
            assert_eq!(id, 1);
            assert!(values.is_empty());
        }
        Incoming::Other => panic!("expected a form.submit"),
    }
}

#[test]
fn an_unknown_method_is_ignored_rather_than_fatal() {
    // A newer canvas talking to an older worker should degrade, not die.
    let line = r#"{"jsonrpc":"2.0","method":"something.new","params":{}}"#;
    assert_eq!(parse_incoming(line), Ok(Incoming::Other));
}

#[test]
fn malformed_lines_are_rejected_with_a_reason() {
    assert!(parse_incoming("not json").is_err());
    assert!(parse_incoming("[1,2,3]").is_err());
    assert!(parse_incoming(r#"{"jsonrpc":"1.0","method":"form.submit","id":1}"#).is_err());
    assert!(parse_incoming(r#"{"method":"form.submit","id":1}"#).is_err());
    // A form.submit with no id could never be answered.
    assert!(parse_incoming(r#"{"jsonrpc":"2.0","method":"form.submit"}"#).is_err());
}

// --- writing to the canvas ---

#[test]
fn a_render_notification_wraps_the_tree_under_params_tree() {
    // dispatch.rs reads params["tree"]; anything else renders nothing.
    let message = render(&json!({ "type": "log" }));
    assert_eq!(message["jsonrpc"], "2.0");
    assert_eq!(message["method"], "ui.render");
    assert_eq!(message["params"]["tree"]["type"], "log");
    assert!(message.get("id").is_none(), "a notification carries no id");
}

#[test]
fn a_log_notification_puts_its_text_under_params_text() {
    // dispatch.rs reads params["text"] as a string.
    let message = log_line("1 + 1 = 2");
    assert_eq!(message["method"], "log.append");
    assert_eq!(message["params"]["text"], "1 + 1 = 2");
    assert!(message.get("id").is_none());
}

#[test]
fn a_response_carries_the_request_id_and_exactly_one_of_result_or_error() {
    let ok = ok_response(3, &Value::from("42"));
    assert_eq!(ok["id"], 3);
    assert_eq!(ok["result"], "42");
    assert!(ok.get("error").is_none());

    let err = error_response(3, "nope");
    assert_eq!(err["id"], 3);
    assert_eq!(err["error"]["message"], "nope");
    assert!(err.get("result").is_none());
    // The canvas reads a bare {"message": ...}, with no JSON-RPC code.
    assert!(err["error"].get("code").is_none());
}

// --- the component trees ---

#[test]
fn the_form_declares_every_field_the_canvas_can_draw() {
    let tree = calculator_form("1+1", AngleMode::Degrees, Radix::Hex);

    assert_eq!(tree["type"], "form");
    assert_eq!(tree["submit_label"], "Evaluate");

    let fields = tree["fields"].as_array().expect("fields");
    assert_eq!(fields.len(), 3);

    assert_eq!(fields[0]["key"], "expr");
    assert_eq!(fields[0]["type"], "text");
    assert_eq!(fields[0]["value"], "1+1");

    assert_eq!(fields[1]["key"], "angle");
    assert_eq!(fields[1]["type"], "dropdown");
    assert_eq!(fields[1]["value"], "degrees");
    assert_eq!(fields[1]["options"], json!(["radians", "degrees"]));

    assert_eq!(fields[2]["key"], "radix");
    assert_eq!(fields[2]["type"], "dropdown");
    assert_eq!(fields[2]["value"], "hex");
    assert_eq!(fields[2]["options"], json!(["decimal", "hex", "binary"]));
}

#[test]
fn every_field_type_is_one_the_canvas_knows() {
    // FieldType in component.rs is exactly these four.
    let known = ["text", "password", "checkbox", "dropdown"];
    let tree = calculator_form("", AngleMode::Radians, Radix::Decimal);

    for field in tree["fields"].as_array().expect("fields") {
        let kind = field["type"].as_str().expect("a field type");
        assert!(known.contains(&kind), "unknown field type {kind}");
    }
}

#[test]
fn a_dropdown_value_is_always_one_of_its_own_options() {
    for (angle, radix) in [
        (AngleMode::Radians, Radix::Decimal),
        (AngleMode::Degrees, Radix::Hex),
        (AngleMode::Radians, Radix::Binary),
    ] {
        let tree = calculator_form("", angle, radix);
        for field in tree["fields"].as_array().expect("fields") {
            if field["type"] != "dropdown" {
                continue;
            }
            let options = field["options"].as_array().expect("options");
            assert!(
                options.contains(&field["value"]),
                "{} defaults to a value not in its options",
                field["key"]
            );
        }
    }
}

#[test]
fn the_detail_panes_are_markdown() {
    let ok = result_detail("2+2", "4");
    assert_eq!(ok["type"], "detail");
    let markdown = ok["markdown"].as_str().expect("markdown");
    assert!(markdown.contains('4'), "the result should be shown");
    assert!(markdown.contains("2+2"), "the expression should be echoed");

    let err = error_detail("2 +", "could not evaluate");
    assert_eq!(err["type"], "detail");
    assert!(err["markdown"]
        .as_str()
        .expect("markdown")
        .contains("could not evaluate"));
}

// --- the dropdown values round-trip ---

#[test]
fn angle_and_radix_survive_a_trip_through_the_form() {
    for angle in [AngleMode::Radians, AngleMode::Degrees] {
        assert_eq!(AngleMode::from_str_or_default(angle.as_str()), angle);
    }
    for radix in [Radix::Decimal, Radix::Hex, Radix::Binary] {
        assert_eq!(Radix::from_str_or_default(radix.as_str()), radix);
    }
}

#[test]
fn an_unknown_dropdown_value_falls_back_rather_than_failing() {
    assert_eq!(
        AngleMode::from_str_or_default("gradians"),
        AngleMode::Radians
    );
    assert_eq!(Radix::from_str_or_default("roman"), Radix::Decimal);
}
