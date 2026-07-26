//! `hyprctl monitors -j` parsing + `MonitorSpec::render` round-trip.

mod common;

use common::{monitor_240hz, monitors_json_two};
use hyprmon::spec::{Monitor, MonitorSpec};

#[test]
fn parses_two_monitor_payload() {
    let parsed: Vec<Monitor> = hyprmon::runner::parse_monitors(&monitors_json_two()).unwrap();
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0], monitor_240hz());
    assert_eq!(parsed[1].name, "HDMI-A-1");
}

#[test]
fn parse_rejects_garbage() {
    assert!(hyprmon::runner::parse_monitors("not json").is_err());
}

#[test]
fn render_spec_with_vrr() {
    let s = MonitorSpec {
        name: "DP-1".to_string(),
        resolution: "1920x1080@240".to_string(),
        position: "0x0".to_string(),
        scale: "1".to_string(),
        transform: None,
        vrr: Some("vrrleft".to_string()),
    };
    assert_eq!(s.render(), "DP-1,1920x1080@240,0x0,1,vrrleft");
}

#[test]
fn render_spec_without_vrr_or_transform() {
    let s = MonitorSpec {
        name: "HDMI-A-1".to_string(),
        resolution: "2560x1200".to_string(),
        position: "1920x0".to_string(),
        scale: "1".to_string(),
        transform: None,
        vrr: None,
    };
    assert_eq!(s.render(), "HDMI-A-1,2560x1200,1920x0,1");
}

#[test]
fn render_spec_with_transform() {
    let s = MonitorSpec {
        name: "DP-2".to_string(),
        resolution: "1920x1080".to_string(),
        position: "0x0".to_string(),
        scale: "1.5".to_string(),
        transform: Some(1),
        vrr: None,
    };
    assert_eq!(s.render(), "DP-2,1920x1080,0x0,1.5,1");
}
