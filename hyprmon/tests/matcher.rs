//! Rule matching: regex by name/description, fallback, first-match-wins, and
//! the invalid-regex-doesn't-match safety net.

mod common;

use common::{monitor_240hz, rules_two};
use hyprmon::matcher::match_monitors;
use hyprmon::rules::{Rule, Rules};
use hyprmon::spec::Monitor;

#[test]
fn matches_both_named_monitors() {
    let monitors = [monitor_240hz(), common::monitor_60hz()];
    let matched = match_monitors(&monitors, &rules_two());
    assert_eq!(matched.len(), 2);
    assert_eq!(matched[0].rule.name, "primary-240hz");
    assert_eq!(matched[1].rule.name, "secondary-60hz");
}

#[test]
fn fallback_catches_unknown_monitor() {
    let unknown = Monitor {
        id: 2,
        name: "DP-3".to_string(),
        description: "Some Projector".to_string(),
        ..monitor_240hz()
    };
    let matched = match_monitors(&[unknown], &rules_two());
    assert_eq!(matched.len(), 1);
    assert_eq!(matched[0].rule.name, "*");
}

#[test]
fn first_match_wins() {
    // Two rules that both match DP-1: the first (more specific) must win.
    let rules = Rules {
        rules: vec![
            Rule {
                name: "specific".to_string(),
                match_name: Some("^DP-1$".to_string()),
                match_description: None,
                resolution: Some("1920x1080@240".to_string()),
                scale: 1.0,
                position: None,
                transform: None,
                vrr: hyprmon::rules::Vrr::Left,
            },
            Rule {
                name: "loose".to_string(),
                match_name: Some("^DP-".to_string()),
                match_description: None,
                resolution: None,
                scale: 1.0,
                position: None,
                transform: None,
                vrr: hyprmon::rules::Vrr::Off,
            },
        ],
    };
    let matched = match_monitors(&[monitor_240hz()], &rules);
    assert_eq!(matched.len(), 1);
    assert_eq!(matched[0].rule.name, "specific");
}

#[test]
fn bad_regex_never_matches() {
    let rules = Rules {
        rules: vec![Rule {
            name: "broken".to_string(),
            match_name: Some("(".to_string()),
            match_description: None,
            resolution: None,
            scale: 1.0,
            position: None,
            transform: None,
            vrr: hyprmon::rules::Vrr::Off,
        }],
    };
    let matched = match_monitors(&[monitor_240hz()], &rules);
    assert!(
        matched.is_empty(),
        "a present-but-invalid regex must not match"
    );
}

#[test]
fn empty_rules_match_nothing() {
    let matched = match_monitors(&[monitor_240hz()], &Rules::default());
    assert!(matched.is_empty());
}

#[test]
fn description_only_rule_matches_on_description() {
    let rules = Rules {
        rules: vec![Rule {
            name: "by-desc".to_string(),
            match_name: None,
            match_description: Some("VG279QM".to_string()),
            resolution: None,
            scale: 1.0,
            position: None,
            transform: None,
            vrr: hyprmon::rules::Vrr::Off,
        }],
    };
    let matched = match_monitors(&[monitor_240hz()], &rules);
    assert_eq!(matched.len(), 1);
}
