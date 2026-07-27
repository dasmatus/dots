//! Forced overrides: matching (name pin vs description fallback), partial vs
//! full field replacement, upsert/remove, and load/save round-trip.

mod common;

use common::{monitor_240hz, monitor_60hz};
use hyprmon::rules::Vrr;
use hyprmon::spec::MonitorSpec;
use hyprmon::{apply_overrides, match_override, OverrideEntry, Overrides};

fn spec(name: &str, resolution: &str, position: &str, scale: &str) -> MonitorSpec {
    MonitorSpec {
        name: name.to_string(),
        resolution: resolution.to_string(),
        position: position.to_string(),
        scale: scale.to_string(),
        transform: None,
        vrr: None,
    }
}

#[test]
fn name_pin_matches_first() {
    let monitor = monitor_60hz();
    let overrides = Overrides {
        entries: vec![
            OverrideEntry {
                name: Some("HDMI-A-1".to_string()),
                resolution: Some("2560x1200@60".to_string()),
                ..Default::default()
            },
            OverrideEntry {
                name: None,
                description: Some(monitor.description.clone()),
                resolution: Some("1600x1200@60".to_string()),
                ..Default::default()
            },
        ],
    };
    // Name pin wins over the description-only entry.
    let matched = match_override(&monitor, &overrides).expect("name pin matches");
    assert_eq!(matched.resolution.as_deref(), Some("2560x1200@60"));
}

#[test]
fn description_fallback_matches_when_no_name_pin() {
    let monitor = monitor_60hz();
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: None,
            description: Some(monitor.description.clone()),
            resolution: Some("2560x1200@60".to_string()),
            ..Default::default()
        }],
    };
    let matched = match_override(&monitor, &overrides).expect("description fallback matches");
    assert_eq!(matched.resolution.as_deref(), Some("2560x1200@60"));
}

#[test]
fn no_match_returns_none() {
    let monitor = monitor_60hz();
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: Some("DP-2".to_string()),
            ..Default::default()
        }],
    };
    assert!(match_override(&monitor, &overrides).is_none());
}

#[test]
fn partial_override_replaces_only_set_fields() {
    let monitors = vec![monitor_60hz()];
    let specs = vec![spec("HDMI-A-1", "2560x1200@60", "1920x0", "1")];
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: Some("HDMI-A-1".to_string()),
            resolution: Some("1920x1080@60".to_string()),
            ..Default::default()
        }],
    };
    let out = apply_overrides(specs, &monitors, &overrides);
    assert_eq!(out[0].resolution, "1920x1080@60");
    // Unpinned fields fall through untouched.
    assert_eq!(out[0].position, "1920x0");
    assert_eq!(out[0].scale, "1");
}

#[test]
fn full_override_replaces_every_field() {
    let monitors = vec![monitor_240hz()];
    let specs = vec![spec("DP-1", "1920x1080@240", "0x0", "1")];
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: Some("DP-1".to_string()),
            resolution: Some("2560x1440@120".to_string()),
            position: Some("0x0".to_string()),
            scale: Some(1.25),
            transform: Some(2),
            vrr: Some(Vrr::Left),
            ..Default::default()
        }],
    };
    let out = apply_overrides(specs, &monitors, &overrides);
    assert_eq!(out[0].resolution, "2560x1440@120");
    assert_eq!(out[0].position, "0x0");
    assert_eq!(out[0].scale, "1.25");
    assert_eq!(out[0].transform, Some(2));
    assert_eq!(out[0].vrr.as_deref(), Some("vrrleft"));
}

#[test]
fn scale_renders_without_trailing_zero() {
    let monitors = vec![monitor_60hz()];
    let specs = vec![spec("HDMI-A-1", "2560x1200@60", "1920x0", "1")];
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: Some("HDMI-A-1".to_string()),
            scale: Some(2.0),
            ..Default::default()
        }],
    };
    let out = apply_overrides(specs, &monitors, &overrides);
    assert_eq!(out[0].scale, "2");
}

#[test]
fn upsert_replaces_existing_name_pin() {
    let mut overrides = Overrides::default();
    overrides.upsert(OverrideEntry {
        name: Some("HDMI-A-1".to_string()),
        resolution: Some("1920x1080@60".to_string()),
        ..Default::default()
    });
    overrides.upsert(OverrideEntry {
        name: Some("HDMI-A-1".to_string()),
        resolution: Some("2560x1200@60".to_string()),
        ..Default::default()
    });
    assert_eq!(overrides.entries.len(), 1);
    assert_eq!(
        overrides.entries[0].resolution.as_deref(),
        Some("2560x1200@60")
    );
}

#[test]
fn upsert_pushes_description_only_entries() {
    let mut overrides = Overrides::default();
    overrides.upsert(OverrideEntry {
        name: None,
        description: Some("Goldstar 25UM58".to_string()),
        ..Default::default()
    });
    overrides.upsert(OverrideEntry {
        name: None,
        description: Some("Goldstar 25UM58".to_string()),
        ..Default::default()
    });
    // No name key to dedupe on → both kept (the author manages these).
    assert_eq!(overrides.entries.len(), 2);
}

#[test]
fn remove_by_name_drops_only_the_pinned_entry() {
    let mut overrides = Overrides {
        entries: vec![
            OverrideEntry {
                name: Some("HDMI-A-1".to_string()),
                ..Default::default()
            },
            OverrideEntry {
                name: None,
                description: Some("Goldstar 25UM58".to_string()),
                ..Default::default()
            },
        ],
    };
    assert!(overrides.remove_by_name("HDMI-A-1"));
    assert_eq!(overrides.entries.len(), 1);
    assert!(overrides.entries[0].name.is_none());
    // Second remove is a no-op.
    assert!(!overrides.remove_by_name("HDMI-A-1"));
}

#[test]
fn load_save_round_trip() {
    let dir = tempfile::tempdir().expect("tmpdir");
    let path = dir.path().join("overrides.json");
    let overrides = Overrides {
        entries: vec![OverrideEntry {
            name: Some("HDMI-A-1".to_string()),
            resolution: Some("2560x1200@60".to_string()),
            scale: Some(1.5),
            vrr: Some(Vrr::Auto),
            ..Default::default()
        }],
    };
    overrides.save_to(&path).expect("save");
    let loaded = Overrides::load_from(path);
    assert_eq!(loaded, overrides);
}

#[test]
fn missing_file_loads_empty() {
    let loaded = Overrides::load_from(std::path::PathBuf::from("/nonexistent/overrides.json"));
    assert!(loaded.entries.is_empty());
}

#[test]
fn garbage_json_loads_empty() {
    let dir = tempfile::tempdir().expect("tmpdir");
    let path = dir.path().join("overrides.json");
    std::fs::write(&path, "{not valid json").expect("write");
    let loaded = Overrides::load_from(path);
    assert!(loaded.entries.is_empty());
}
