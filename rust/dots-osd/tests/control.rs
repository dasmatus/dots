//! The two parsing decisions the actuators make: which input device is the
//! touchpad, and how a device name is safe to hand to Hyprland's Lua parser.

use dots_osd::control::{lua_string, touchpad_name, Switch};

/// Captured from `hyprctl devices -j` on the laptop this was written for. The
/// same hardware appears twice, once as a touchpad, once as a plain pointer,
/// which is the whole reason the suffix is what the match looks at.
const DEVICES: &str = r#"{
"mice": [
    {
        "address": "0x64227896ee70",
        "name": "elan0524:00-04f3:3215-touchpad",
        "defaultSpeed": 0.00000
    },    {
        "address": "0x6422789a9cf0",
        "name": "elan0524:00-04f3:3215-mouse",
        "defaultSpeed": 0.00000
    }
],
"keyboards": [
    {
        "address": "0x642276e0f870",
        "name": "video-bus",
        "layout": "us"
    }
],
"tablets": [],
"touch": [],
"switches": []
}"#;

#[test]
fn the_touchpad_is_picked_out_of_the_pointers_beside_it() {
    assert_eq!(
        touchpad_name(DEVICES).as_deref(),
        Some("elan0524:00-04f3:3215-touchpad")
    );
}

#[test]
fn a_machine_with_only_a_mouse_has_no_touchpad() {
    let json = r#"{"mice":[{"name":"logitech-mx-master"}],"keyboards":[]}"#;
    assert_eq!(touchpad_name(json), None);
}

#[test]
fn trackpad_spelling_is_matched_too() {
    let json = r#"{"mice":[{"name":"apple-internal-trackpad"}]}"#;
    assert_eq!(
        touchpad_name(json).as_deref(),
        Some("apple-internal-trackpad")
    );
}

#[test]
fn the_match_ignores_case() {
    let json = r#"{"mice":[{"name":"SynPS2-Synaptics-TouchPad"}]}"#;
    assert_eq!(
        touchpad_name(json).as_deref(),
        Some("SynPS2-Synaptics-TouchPad")
    );
}

#[test]
fn unparseable_output_is_no_touchpad_rather_than_a_panic() {
    assert_eq!(touchpad_name("not json at all"), None);
    assert_eq!(touchpad_name(""), None);
}

#[test]
fn an_explicit_switch_ignores_the_current_state() {
    // `on` and `off` are the escape hatch for a desynced toggle, so they have
    // to mean what they say no matter what the state file claims.
    assert!(Switch::On.resolve(false));
    assert!(Switch::On.resolve(true));
    assert!(!Switch::Off.resolve(false));
    assert!(!Switch::Off.resolve(true));
}

#[test]
fn a_toggle_is_the_opposite_of_where_it_started() {
    // Getting this backwards means every keypress reports the change it did
    // not make, which is worse than doing nothing at all.
    assert!(Switch::Toggle.resolve(false));
    assert!(!Switch::Toggle.resolve(true));
}

#[test]
fn a_plain_name_quotes_to_itself() {
    assert_eq!(lua_string("elan0524-touchpad"), "\"elan0524-touchpad\"");
}

#[test]
fn a_quote_in_a_device_name_cannot_end_the_literal() {
    // The names come from the kernel. An unescaped quote here would close the
    // string early and hand the remainder to Hyprland's Lua parser as code.
    assert_eq!(
        lua_string(r#"evil", enabled = true }) os.exit() --"#),
        r#""evil\", enabled = true }) os.exit() --""#
    );
}

#[test]
fn backslashes_and_newlines_survive_escaping() {
    assert_eq!(lua_string(r"back\slash"), r#""back\\slash""#);
    assert_eq!(lua_string("two\nlines"), r#""two\nlines""#);
}
