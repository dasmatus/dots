//! The declarative ruleset. Mirrors the JSON the Nix module writes to
//! `~/.config/hyprmon/rules.json`: a list of rules, each matching monitors by
//! `name` or `description` regex, plus a `fallback` rule keyed on `"*"` that
//! applies to any monitor no rule matched. Rules are evaluated in list order;
//! the first match wins.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::{Deserialize, Serialize};

/// VRR policy for a monitor. `Off` (the Hyprland default) emits no `vrr*`
/// token at all; `Left`/`Right`/`Auto` map to the `vrrleft`/`vrrright`/`vrrauto`
/// keyword suffix respectively.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Vrr {
    /// No `vrr*` token — Hyprland's built-in default (VRR off).
    #[default]
    Off,
    /// `vrrleft` — VRR on for fullscreen/app-driven, left to the compositor.
    Left,
    /// `vrrright` — explicit "always VRR" flavour Hyprland exposes.
    Right,
    /// `vrrauto` — driver decides.
    Auto,
}

impl Vrr {
    /// Render as the trailing `monitor` keyword token, or `None` for `Off`.
    #[must_use]
    pub fn token(self) -> Option<String> {
        match self {
            Vrr::Off => None,
            Vrr::Left => Some("vrrleft".to_string()),
            Vrr::Right => Some("vrrright".to_string()),
            Vrr::Auto => Some("vrrauto".to_string()),
        }
    }
}

/// One declarative rule. `match_name` / `match_description` are optional
/// regexes (either or both may be present; a monitor matches when every
/// present regex matches). The fallback rule is the one with `name == "*"`
/// and no regexes. `position` is optional; the planner fills it in for a
/// horizontal left-to-right layout, but an explicit `position` pins the
/// monitor absolutely.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rule {
    /// Human-readable label, also the match key for the fallback rule (`"*"`).
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_description: Option<String>,
    /// `WxH@R` (e.g. `1920x1080@240`). `@R` is optional; when omitted the
    /// monitor's current refresh rate is used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    /// Hyprland monitor scale (e.g. `1`, `1.5`). Defaults to `1`.
    #[serde(default = "default_scale")]
    pub scale: f64,
    /// Absolute `XxY` position. When `None`, the planner places this monitor
    /// to the right of the previous one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<u8>,
    #[serde(default)]
    pub vrr: Vrr,
}

fn default_scale() -> f64 {
    1.0
}

/// The full ruleset: an ordered list of rules, the first of which is usually
/// the fallback (`name == "*"`). The Nix module is the source of truth; at
/// runtime `hyprmon` reads this from `~/.config/hyprmon/rules.json`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Rules {
    pub rules: Vec<Rule>,
}

/// `$XDG_CONFIG_HOME/hyprmon/rules.json` — the declarative rules file the
/// Nix module writes.
#[must_use]
pub fn rules_file() -> PathBuf {
    let base =
        std::env::var("XDG_CONFIG_HOME").map_or_else(|_| home_dir().join(".config"), PathBuf::from);
    base.join("hyprmon").join("rules.json")
}

fn home_dir() -> PathBuf {
    std::env::var("HOME").map_or_else(|_| PathBuf::from("/"), PathBuf::from)
}

impl Rules {
    /// Load from the default path; missing/garbage → empty rules (the planner
    /// then falls back to per-monitor `preferred,auto,1`).
    #[must_use]
    pub fn load() -> Self {
        Self::load_from(rules_file())
    }

    #[must_use]
    pub fn load_from(path: PathBuf) -> Self {
        match fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    /// Serialize to JSON for the Nix module to write. Kept here so the wire
    /// format lives next to the struct.
    pub fn save_to(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).ok();
        }
        let mut json = serde_json::to_string_pretty(self)?;
        json.push('\n');
        fs::write(path, json).with_context(|| format!("saving rules to {}", path.display()))
    }
}
