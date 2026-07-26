//! Shared fixtures for the integration tests: synthetic `hyprctl monitors -j`
//! payloads and rulesets mirroring the two-monitor setup in AGENTS.md (a 27"
//! 1080p 240Hz VRR panel and a 25" 1200p 60Hz panel).
//
// Each test binary uses only a subset, so dead code is allowed.
#![allow(dead_code)]

use hyprmon::rules::{Rule, Rules, Vrr};
use hyprmon::spec::Monitor;

/// The 27" 1080p 240Hz VRR panel — primary, leftmost.
pub fn monitor_240hz() -> Monitor {
    Monitor {
        id: 0,
        name: "DP-1".to_string(),
        description: "Ancor Communications ASUS VG279QM 0x00012345".to_string(),
        width: 1920,
        height: 1080,
        refresh_rate: 239.76,
        current_format: "1920x1080@239.76".to_string(),
        make: "Ancor Communications".to_string(),
        model: "ASUS VG279QM".to_string(),
        serial: "0x00012345".to_string(),
        transform: 0,
        vrr: true,
        available_modes: vec!["1920x1080@239.76".to_string(), "1920x1080@60".to_string()],
    }
}

/// The 25" 1200p 60Hz panel — secondary, to the right of the 240Hz one.
pub fn monitor_60hz() -> Monitor {
    Monitor {
        id: 1,
        name: "HDMI-A-1".to_string(),
        description: "Goldstar Company Ltd 25UM58 0x00067890".to_string(),
        width: 2560,
        height: 1200,
        refresh_rate: 59.95,
        current_format: "2560x1200@59.95".to_string(),
        make: "Goldstar Company Ltd".to_string(),
        model: "25UM58".to_string(),
        serial: "0x00067890".to_string(),
        transform: 0,
        vrr: false,
        available_modes: vec!["2560x1200@59.95".to_string()],
    }
}

/// The two-monitor payload as `hyprctl monitors -j` would emit it.
pub fn monitors_json_two() -> String {
    serde_json::to_string(&[monitor_240hz(), monitor_60hz()]).unwrap()
}

/// The declarative ruleset for the two-monitor setup: 240Hz VRR on the left,
/// 60Hz on the right, plus a fallback for unknown monitors (e.g. a
/// hotplugged projector).
pub fn rules_two() -> Rules {
    Rules {
        rules: vec![
            Rule {
                name: "primary-240hz".to_string(),
                match_name: Some("^DP-1$".to_string()),
                match_description: Some("VG279QM".to_string()),
                resolution: Some("1920x1080@240".to_string()),
                scale: 1.0,
                position: None,
                transform: None,
                vrr: Vrr::Left,
            },
            Rule {
                name: "secondary-60hz".to_string(),
                match_name: Some("^HDMI-A-1$".to_string()),
                match_description: Some("25UM58".to_string()),
                resolution: Some("2560x1200".to_string()),
                scale: 1.0,
                position: None,
                transform: None,
                vrr: Vrr::Off,
            },
            Rule {
                name: "*".to_string(),
                match_name: None,
                match_description: None,
                resolution: None,
                scale: 1.0,
                position: None,
                transform: None,
                vrr: Vrr::Off,
            },
        ],
    }
}

/// A [`hyprmon::runner::HyprCtl`] backed by a fixed JSON payload and a
/// shared log of the `keyword` calls. `monitors_json` returns the captured
/// payload; `keyword` records the spec so the test can assert on it.
pub use hyprmon::runner::HyprCtl;
use std::sync::Mutex;

pub struct FakeCtl {
    pub json: String,
    pub keywords: Mutex<Vec<String>>,
}

impl FakeCtl {
    pub fn new(json: &str) -> Self {
        Self {
            json: json.to_string(),
            keywords: Mutex::new(Vec::new()),
        }
    }
}

impl HyprCtl for FakeCtl {
    fn monitors_json(&self) -> Result<String, String> {
        Ok(self.json.clone())
    }
    fn keyword(&self, spec: &str) -> Result<String, String> {
        self.keywords.lock().unwrap().push(spec.to_string());
        Ok("ok".to_string())
    }
}
