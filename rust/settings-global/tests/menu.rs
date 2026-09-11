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
/// int rows, `select` for the layout row, with `min`/`max`/`step`/`options`
/// reaching the payload regardless of whether the key exists. The current
/// *value*, though, must be the row's real schema default (`5`, `"dwindle"`),
/// not `0`/`""`, because a missing key is not the same as an unset one: it
/// means the value defaults.nix already supplies, and reporting the wrong
/// number here is how a Settings-panel Save would flatten a user's gaps to
/// zero on the first edit of an unrelated field.
#[test]
fn wm_int_and_select_rows_dump_their_schema_even_when_absent() {
    let s = Settings::parse(SRC).unwrap();
    let items = dump(&s);

    let gaps_in = items.iter().find(|i| i.key == "wmGapsIn").unwrap();
    assert_eq!(gaps_in.kind, "number");
    assert_eq!(gaps_in.value, json!(5));
    assert_eq!(gaps_in.min, Some(0));
    assert_eq!(gaps_in.max, Some(50));
    assert_eq!(gaps_in.step, Some(1));

    let layout = items.iter().find(|i| i.key == "wmLayout").unwrap();
    assert_eq!(layout.kind, "select");
    assert_eq!(layout.value, json!("dwindle"));
    assert_eq!(layout.options, Some(&["dwindle", "master"][..]));

    // A checkbox/text row must not carry number/select-only fields.
    let hostname = items.iter().find(|i| i.key == "hostname").unwrap();
    assert_eq!(hostname.min, None);
    assert_eq!(hostname.options, None);
}

/// The regression this whole fix exists for: every key this task added must
/// dump its `nix/system/defaults.nix` value when the store has never heard of
/// it, not the type's zero value. Values here were independently confirmed
/// against defaults.nix via `nix-instantiate --eval --strict --json`. If
/// either file changes without the other, this is the test that catches it.
#[test]
fn every_new_key_dumps_its_real_default_when_absent_from_the_store() {
    let s = Settings::parse(SRC).unwrap();
    let items = dump(&s);
    let value_of = |key: &str| items.iter().find(|i| i.key == key).unwrap().value.clone();

    assert_eq!(value_of("timezone"), json!("Europe/Bratislava"));
    assert_eq!(value_of("desktop"), json!("hyprland"));
    assert_eq!(value_of("wmGapsIn"), json!(5));
    assert_eq!(value_of("wmGapsOut"), json!(15));
    assert_eq!(value_of("wmBorderSize"), json!(2));
    assert_eq!(value_of("wmFollowMouse"), json!(true));
    assert_eq!(value_of("wmAnimations"), json!(true));
    assert_eq!(value_of("wmLayout"), json!("dwindle"));
    assert_eq!(
        value_of("aiOllamaEndpoint"),
        json!("http://127.0.0.1:11434")
    );
    assert_eq!(value_of("gitSigningKey"), json!(""));
}

/// aiClaude/aiCodex/aiOllama predate this task but share the same schema-vs-
/// zero-value split: nix/system/defaults.nix defaults all three to `true`, so a
/// settings.nix from before the installer wrote them (or one hand-edited to
/// drop a line) must not silently read as every AI integration disabled.
#[test]
fn ai_toggles_default_to_true_when_absent_matching_defaults_nix() {
    let s = Settings::parse("{\n  hostname = \"box\";\n}\n").unwrap();
    let items = dump(&s);
    let value_of = |key: &str| items.iter().find(|i| i.key == key).unwrap().value.clone();
    assert_eq!(value_of("aiOllama"), json!(true));
    assert_eq!(value_of("aiClaude"), json!(true));
    assert_eq!(value_of("aiCodex"), json!(true));
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
