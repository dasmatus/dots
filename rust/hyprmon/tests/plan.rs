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
    // 60Hz secondary to the right (x=1920), no VRR token. The rule pins
    // `2560x1200` with no refresh; the planner appends the max advertised
    // rate (59.95 → rounded up to 60) so Hyprland doesn't default to 59.95.
    assert_eq!(specs[1].name, "HDMI-A-1");
    assert_eq!(specs[1].position, "1920x0");
    assert_eq!(specs[1].resolution, "2560x1200@60");
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
    // Unknown monitor matched only by the fallback gets `preferred` with the
    // max advertised refresh (239.76 → rounded up to 240).
    let mut unknown = monitor_240hz();
    unknown.name = "DP-9".to_string();
    unknown.description = "Mystery Panel".to_string();
    let matched = match_monitors(&[unknown], &rules_two());
    let specs = plan(&matched);
    assert_eq!(specs[0].resolution, "preferred@240");
}

#[test]
fn nvidia_empty_modes_falls_back_to_live_refresh_rounded_up() {
    // The NVIDIA proprietary driver doesn't populate `availableModes`, so a
    // rule pinning `WxH` with no refresh must fall back to the live
    // `refreshRate` (rounded up) rather than emit a bare resolution that
    // Hyprland would default to 59.95 Hz.
    let mut hdmi = common::monitor_60hz();
    hdmi.available_modes = Vec::new();
    let matched = match_monitors(&[hdmi], &rules_two());
    let specs = plan(&matched);
    let hdmi = specs
        .iter()
        .find(|s| s.name == "HDMI-A-1")
        .expect("HDMI secondary matched");
    assert_eq!(hdmi.resolution, "2560x1200@60");
}

#[test]
fn nvidia_empty_modes_preferred_falls_back_to_live_refresh() {
    // Same NVIDIA workaround on the `preferred` path: no modes, so the live
    // 59.95 Hz is rounded up to 60.
    let mut nvidia = common::monitor_60hz();
    nvidia.available_modes = Vec::new();
    nvidia.name = "DP-9".to_string();
    nvidia.description = "NVIDIA HDMI sink".to_string();
    let matched = match_monitors(&[nvidia], &rules_two());
    let specs = plan(&matched);
    assert_eq!(specs[0].resolution, "preferred@60");
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
