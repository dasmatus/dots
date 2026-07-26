//! Layout planning: left-to-right packing, explicit position pin,
//! resolution/scale/refresh/vrr rendering, and the `preferred` fallback.

mod common;

use common::{monitor_240hz, rules_two};
use hyprmon::matcher::match_monitors;
use hyprmon::plan::plan;
use hyprmon::rules::Vrr;

#[test]
fn plans_two_monitors_left_to_right() {
    let monitors = [monitor_240hz(), common::monitor_60hz()];
    let matched = match_monitors(&monitors, &rules_two());
    let specs = plan(&matched);
    assert_eq!(specs.len(), 2);
    // 240Hz primary at 0x0, VRR left, explicit @240.
    assert_eq!(specs[0].name, "DP-1");
    assert_eq!(specs[0].position, "0x0");
    assert_eq!(specs[0].resolution, "1920x1080@240");
    assert_eq!(specs[0].vrr.as_deref(), Some("vrrleft"));
    // 60Hz secondary to the right (x=1920), no VRR token.
    assert_eq!(specs[1].name, "HDMI-A-1");
    assert_eq!(specs[1].position, "1920x0");
    assert_eq!(specs[1].resolution, "2560x1200");
    assert_eq!(specs[1].vrr, None);
}

#[test]
fn empty_match_yields_empty_plan() {
    assert!(plan(&[]).is_empty());
}

#[test]
fn explicit_position_pins_and_advances_cursor() {
    // Secondary pinned at 3840x0; a third fallback monitor should land at
    // 3840+2560 = 6400.
    let monitors = [
        monitor_240hz(),
        common::monitor_60hz(),
        common::monitor_240hz(),
    ];
    let mut rules = rules_two();
    rules.rules[1].position = Some("3840x0".to_string()); // pin secondary
    let matched = match_monitors(&monitors, &rules);
    let specs = plan(&matched);
    assert_eq!(specs[1].position, "3840x0");
    // The third monitor matched the fallback; cursor advanced from the
    // pinned secondary's right edge (3840 + 2560 = 6400).
    assert_eq!(specs[2].position, "6400x0");
}

#[test]
fn fractional_scale_renders_with_dot() {
    let monitors = [monitor_240hz()];
    let mut rules = rules_two();
    rules.rules[0].scale = 1.5;
    let matched = match_monitors(&monitors, &rules);
    let specs = plan(&matched);
    assert_eq!(specs[0].scale, "1.5");
}

#[test]
fn integral_scale_drops_trailing_zero() {
    let monitors = [monitor_240hz()];
    let mut rules = rules_two();
    rules.rules[0].scale = 2.0;
    let matched = match_monitors(&monitors, &rules);
    let specs = plan(&matched);
    assert_eq!(specs[0].scale, "2");
}

#[test]
fn fallback_rule_emits_preferred_when_no_resolution() {
    // Unknown monitor matched only by the fallback gets `preferred` (with
    // the live refresh rate as `@R` when nonzero).
    let mut unknown = monitor_240hz();
    unknown.name = "DP-9".to_string();
    unknown.description = "Mystery Panel".to_string();
    let matched = match_monitors(&[unknown], &rules_two());
    let specs = plan(&matched);
    assert_eq!(specs[0].resolution, "preferred@239.76");
}

#[test]
fn transform_is_emitted_when_set() {
    let monitors = [monitor_240hz()];
    let mut rules = rules_two();
    rules.rules[0].transform = Some(2);
    let matched = match_monitors(&monitors, &rules);
    let specs = plan(&matched);
    assert_eq!(specs[0].transform, Some(2));
    assert_eq!(specs[0].render(), "DP-1,1920x1080@240,0x0,1,2,vrrleft");
}

#[test]
fn vrr_off_emits_no_token() {
    let monitors = [monitor_240hz()];
    let mut rules = rules_two();
    rules.rules[0].vrr = Vrr::Off;
    let matched = match_monitors(&monitors, &rules);
    let specs = plan(&matched);
    assert!(specs[0].vrr.is_none());
    assert!(!specs[0].render().contains("vrr"));
}
