//! Tests for the menu model backing the headless frontends: one item per
//! field, `dump`/`form_fields` show live values with the right JSON `type`,
//! and `apply_values` validates before it writes anything.

use global_settings::menu::{apply_values, dump, form_fields, ITEMS};
use global_settings::settings::Settings;
use serde_json::json;

const SRC: &str = "{\n  hostname = \"box\";\n  gitName = \"Ada\";\n  gitEmail = \"a@b.com\";\n  aiClaude = true;\n  aiCodex = false;\n  aiOllama = true;\n}\n";

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

/// SRC deliberately omits protonEmail, the state every existing
/// /var/lib/dots/settings.nix is in before this key existed. The row must
/// still appear, typed as text and valued empty, because an empty address is
/// what tells the settings panel's Proton page it is unconfigured.
#[test]
fn proton_email_row_defaults_to_empty_when_the_key_is_absent() {
    let s = Settings::parse(SRC).unwrap();
    let items = dump(&s);
    let proton = items.iter().find(|i| i.key == "protonEmail").unwrap();
    assert_eq!(proton.kind, "text");
    assert_eq!(proton.value, json!(""));
    assert_eq!(proton.prompt, Some("Proton email"));
}

#[test]
fn proton_email_round_trips_through_apply_values() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "protonEmail": "me@proton.me" });
    assert!(apply_values(&mut s, values.as_object().unwrap()).unwrap());
    assert_eq!(s.get_str("protonEmail").as_deref(), Some("me@proton.me"));

    let bad = serde_json::json!({ "protonEmail": "nodomain" });
    assert!(apply_values(&mut s, bad.as_object().unwrap()).is_err());
    assert_eq!(s.get_str("protonEmail").as_deref(), Some("me@proton.me"));
}

/// SRC omits every window-manager key (the state every settings.nix is in
/// before this feature), so their rows must still dump: `number` for the
/// int rows, current value falling back to 0, with `min`/`max`/`step`
/// reaching the payload; `select` for the layout row, with `options`.
#[test]
fn wm_int_and_select_rows_dump_their_schema_even_when_absent() {
    let s = Settings::parse(SRC).unwrap();
    let items = dump(&s);

    let gaps_in = items.iter().find(|i| i.key == "wmGapsIn").unwrap();
    assert_eq!(gaps_in.kind, "number");
    assert_eq!(gaps_in.value, json!(0));
    assert_eq!(gaps_in.min, Some(0));
    assert_eq!(gaps_in.max, Some(50));
    assert_eq!(gaps_in.step, Some(1));

    let layout = items.iter().find(|i| i.key == "wmLayout").unwrap();
    assert_eq!(layout.kind, "select");
    assert_eq!(layout.value, json!(""));
    assert_eq!(layout.options, Some(&["dwindle", "master"][..]));

    // A checkbox/text row must not carry number/select-only fields.
    let hostname = items.iter().find(|i| i.key == "hostname").unwrap();
    assert_eq!(hostname.min, None);
    assert_eq!(hostname.options, None);
}

#[test]
fn dump_serializes_int_as_a_json_number_with_bounds_and_no_string_coercion() {
    let mut s = Settings::parse(SRC).unwrap();
    s.set_int("wmGapsIn", 7);
    let json = serde_json::to_value(dump(&s)).unwrap();
    let gaps_in = json
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["key"] == "wmGapsIn")
        .unwrap();
    assert_eq!(gaps_in["type"], "number");
    assert!(gaps_in["value"].is_number(), "{gaps_in}");
    assert_eq!(gaps_in["value"], 7);
    assert_eq!(gaps_in["min"], 0);
    assert_eq!(gaps_in["max"], 50);
    assert_eq!(gaps_in["step"], 1);
}

#[test]
fn dump_serializes_select_options_to_the_documented_shape() {
    let s = Settings::parse(SRC).unwrap();
    let json = serde_json::to_value(dump(&s)).unwrap();
    let layout = json
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["key"] == "wmLayout")
        .unwrap();
    assert_eq!(layout["type"], "select");
    assert_eq!(layout["options"], json!(["dwindle", "master"]));
}

#[test]
fn apply_values_round_trips_an_int_field() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "wmGapsIn": 12 });
    assert!(apply_values(&mut s, values.as_object().unwrap()).unwrap());
    assert_eq!(s.get_int("wmGapsIn"), Some(12));
}

#[test]
fn apply_values_rejects_an_out_of_range_int_and_leaves_settings_untouched() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "wmGapsIn": 999 });
    let err = apply_values(&mut s, values.as_object().unwrap()).unwrap_err();
    assert!(err.contains("wmGapsIn"), "{err}");
    assert_eq!(s.get_int("wmGapsIn"), None);
}

#[test]
fn apply_values_rejects_a_non_integer_json_value_for_an_int_field() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "wmGapsIn": "5" });
    let err = apply_values(&mut s, values.as_object().unwrap()).unwrap_err();
    assert!(err.contains("wmGapsIn"), "{err}");
}

#[test]
fn apply_values_round_trips_a_select_field() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "wmLayout": "master" });
    assert!(apply_values(&mut s, values.as_object().unwrap()).unwrap());
    assert_eq!(s.get_str("wmLayout").as_deref(), Some("master"));
}

#[test]
fn apply_values_rejects_a_select_value_outside_its_options() {
    let mut s = Settings::parse(SRC).unwrap();
    let values = serde_json::json!({ "wmLayout": "tiling-but-fancy" });
    let err = apply_values(&mut s, values.as_object().unwrap()).unwrap_err();
    assert!(err.contains("wmLayout"), "{err}");
    assert_eq!(s.get_str("wmLayout"), None);
}

#[test]
fn form_fields_include_number_and_select_kinds() {
    let s = Settings::parse(SRC).unwrap();
    let fields = form_fields(&s);
    let gaps_in = fields.iter().find(|f| f.key == "wmGapsIn").unwrap();
    assert_eq!(gaps_in.kind, "number");
    let layout = fields.iter().find(|f| f.key == "wmLayout").unwrap();
    assert_eq!(layout.kind, "select");
}
