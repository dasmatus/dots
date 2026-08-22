//! Tests for the menu model backing the headless frontends: one item per
//! field, `dump`/`form_fields` show live values with the right JSON `type`,
//! and `apply_values` validates before it writes anything.

use global_settings::menu::{apply_values, dump, form_fields, ITEMS};
use global_settings::settings::Settings;
use serde_json::json;

const SRC: &str = "{\n  hostname = \"box\";\n  gitName = \"Matus\";\n  gitEmail = \"a@b.com\";\n  aiClaude = true;\n  aiCodex = false;\n  aiOllama = true;\n}\n";

#[test]
fn dump_has_one_entry_per_item() {
    let s = Settings::parse(SRC).unwrap();
    assert_eq!(dump(&s).len(), ITEMS.len());
}

#[test]
fn dump_shows_current_values_and_types() {
    let s = Settings::parse(SRC).unwrap();
    let items = dump(&s);
    let hostname = items.iter().find(|i| i.key == "hostname").unwrap();
    assert_eq!(hostname.kind, "text");
    assert_eq!(hostname.value, json!("box"));
    assert_eq!(hostname.prompt, Some("Hostname"));

    let ollama = items.iter().find(|i| i.key == "aiOllama").unwrap();
    assert_eq!(ollama.kind, "checkbox");
    assert_eq!(ollama.value, json!(true));
    assert_eq!(ollama.prompt, None);

    let codex = items.iter().find(|i| i.key == "aiCodex").unwrap();
    assert_eq!(codex.value, json!(false));
}

#[test]
fn dump_serializes_to_the_documented_shape() {
    let s = Settings::parse(SRC).unwrap();
    let json = serde_json::to_value(dump(&s)).unwrap();
    let hostname = json
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["key"] == "hostname")
        .unwrap();
    assert_eq!(hostname["type"], "text");
    assert_eq!(hostname["value"], "box");
    assert_eq!(hostname["prompt"], "Hostname");

    let ollama = json
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["key"] == "aiOllama")
        .unwrap();
    assert_eq!(ollama["type"], "checkbox");
    assert_eq!(ollama["value"], true);
    // Toggle rows carry no prompt at all.
    assert!(ollama.get("prompt").is_none(), "{ollama}");
}

#[test]
fn no_exit_row_remains() {
    let s = Settings::parse(SRC).unwrap();
    assert_eq!(ITEMS.len(), 6);
    assert!(!dump(&s).iter().any(|i| i.label == "Exit"));
}

#[test]
fn form_fields_match_dump_minus_prompt() {
    let s = Settings::parse(SRC).unwrap();
    let fields = form_fields(&s);
    assert_eq!(fields.len(), ITEMS.len());
    let hostname = fields.iter().find(|f| f.key == "hostname").unwrap();
    assert_eq!(hostname.kind, "text");
    assert_eq!(hostname.value, json!("box"));
}

#[test]
fn apply_values_writes_only_changed_fields() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::from_value(json!({
        "hostname": "box", // unchanged
        "aiCodex": true,   // changed
    }))
    .unwrap();
    let changed = apply_values(&mut s, &values).unwrap();
    assert!(changed);
    assert_eq!(s.get_bool("aiCodex"), Some(true));
    assert_eq!(s.get_str("hostname").as_deref(), Some("box"));
}

#[test]
fn apply_values_reports_no_change_when_nothing_differs() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::from_value(json!({ "hostname": "box" })).unwrap();
    let changed = apply_values(&mut s, &values).unwrap();
    assert!(!changed);
}

#[test]
fn apply_values_rejects_invalid_field_and_leaves_settings_untouched() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::from_value(json!({ "hostname": "UpperCase" })).unwrap();
    let err = apply_values(&mut s, &values).unwrap_err();
    assert!(err.contains("a-z"), "{err}");
    assert_eq!(s.get_str("hostname").as_deref(), Some("box"));
}

#[test]
fn apply_values_rejects_wrong_json_type() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::from_value(json!({ "aiCodex": "not a bool" })).unwrap();
    let err = apply_values(&mut s, &values).unwrap_err();
    assert!(err.contains("aiCodex"), "{err}");
    assert_eq!(s.get_bool("aiCodex"), Some(false));
}

#[test]
fn apply_values_stops_at_first_invalid_field_in_items_order() {
    // gitName comes before hostname in ITEMS; an invalid hostname must not
    // let a later-in-values-but-earlier-in-ITEMS field apply first.
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::from_value(json!({
        "hostname": "UpperCase",
        "gitEmail": "also bad",
    }))
    .unwrap();
    let err = apply_values(&mut s, &values).unwrap_err();
    // gitEmail is earlier in ITEMS than hostname, so its failure surfaces first.
    assert!(err.contains('@') || err.contains("whitespace"), "{err}");
    assert_eq!(s.get_str("gitEmail").as_deref(), Some("a@b.com"));
    assert_eq!(s.get_str("hostname").as_deref(), Some("box"));
}
