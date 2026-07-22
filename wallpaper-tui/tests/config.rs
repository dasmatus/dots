//! Config / State / effective_output merge. Ports the config portion of the
//! pytest suite (round-trip, missing-file defaults, declarative+override merge).

use std::collections::BTreeMap;
use std::fs;

use tempfile::tempdir;
use wallpaper_tui::config::{
    effective_output, Config, OutputConfig, OutputOverride, State, DEFAULT_COLOR,
};

#[test]
fn state_round_trip() {
    let d = tempdir().unwrap();
    let path = d.path().join("state.json");
    let mut outputs = BTreeMap::new();
    outputs.insert(
        "eDP-1".to_string(),
        OutputOverride {
            path: Some("/w/p.jpg".to_string()),
            mode: Some("fit".to_string()),
            fill_color: None,
        },
    );
    let state = State { outputs };
    state.save_to(path.clone()).unwrap();
    let loaded = State::load_from(path);
    assert_eq!(loaded, state);
}

#[test]
fn missing_file_defaults() {
    let d = tempdir().unwrap();
    let cfg = Config::load_from(d.path().join("nope.json"));
    assert!(cfg.wallpaper_folder.is_empty());
    assert!(cfg.outputs.is_empty());
    let st = State::load_from(d.path().join("nope.json"));
    assert!(st.outputs.is_empty());
}

#[test]
fn effective_output_merge() {
    let mut outputs = BTreeMap::new();
    outputs.insert(
        "eDP-1".to_string(),
        OutputConfig {
            path: Some("/decl/default.jpg".to_string()),
            mode: "fill".to_string(),
            fill_color: "#111111".to_string(),
        },
    );
    let config = Config {
        wallpaper_folder: "/w".to_string(),
        recursive: true,
        current_output: "eDP-1".to_string(),
        transition_type: "grow".to_string(),
        transition_duration: 1.0,
        outputs,
    };
    let state = State::default();
    let eff = effective_output(&config, &state, "eDP-1");
    assert_eq!(eff.path, "/decl/default.jpg");
    assert_eq!(eff.mode, "fill");
    assert_eq!(eff.fill_color, "#111111");
}

#[test]
fn effective_output_override_wins_and_empty_falls_back() {
    let mut decl = BTreeMap::new();
    decl.insert(
        "eDP-1".to_string(),
        OutputConfig {
            path: Some("/decl.jpg".to_string()),
            mode: "fit".to_string(),
            fill_color: "#222222".to_string(),
        },
    );
    let config = Config {
        outputs: decl,
        ..Config::default()
    };
    let mut over = BTreeMap::new();
    over.insert(
        "eDP-1".to_string(),
        OutputOverride {
            path: Some("/override.jpg".to_string()),
            mode: Some("".to_string()), // empty → fall back to declarative
            fill_color: None,           // None → fall back to declarative
        },
    );
    let state = State { outputs: over };
    let eff = effective_output(&config, &state, "eDP-1");
    assert_eq!(eff.path, "/override.jpg");
    assert_eq!(eff.mode, "fit"); // override empty → declarative
    assert_eq!(eff.fill_color, "#222222"); // override None → declarative
}

#[test]
fn effective_output_missing_output_uses_defaults() {
    let config = Config::default();
    let state = State::default();
    let eff = effective_output(&config, &state, "HDMI-1");
    assert!(eff.path.is_empty());
    assert_eq!(eff.mode, "fill");
    assert_eq!(eff.fill_color, DEFAULT_COLOR);
}

#[test]
fn config_ignores_garbage() {
    let d = tempdir().unwrap();
    let path = d.path().join("config.json");
    fs::write(path, "not json at all").unwrap();
    let cfg = Config::load_from(d.path().join("config.json"));
    assert_eq!(cfg, Config::default());
}
