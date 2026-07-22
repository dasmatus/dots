//! Declarative (read-only, from Nix) config and writable runtime state, plus
//! the per-output effective-value merge. Mirrors the two-file split the Nix
//! module writes: ``config.json`` is owned by Nix, ``state.json`` holds the
//! TUI's runtime overrides.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::{Deserialize, Serialize};

/// Fill color for the ``c`` cycle (letterbox modes) — Tokyonight-adjacent.
pub const COLOR_PALETTE: &[&str] = &[
    "#d2a1a1", "#1a1b26", "#000000", "#ffffff", "#7aa2f7", "#bb9af7", "#9ece6a", "#f7768e",
];
pub const DEFAULT_COLOR: &str = "#d2a1a1";

pub const MODES: &[&str] = &["fill", "stretch", "fit", "center", "tile"];

/// Fallback accent = Tokyonight blue (the rofi accent), so a failed extraction
/// leaves the themes visually unchanged rather than blank.
pub const DEFAULT_ACCENT: &str = "#7aa2f7";
pub const DEFAULT_ACCENT_DARK: &str = "#3b4261";
pub const DEFAULT_ACCENT_LIGHT: &str = "#a9b1d6";

/// ad-hoc resolution of an XDG-ish base dir, matching the Python's
/// ``os.environ.get(..., default)`` behaviour.
fn xdg_dir(env: &str, default_sub: &str) -> PathBuf {
    match std::env::var(env) {
        Ok(s) if !s.is_empty() => PathBuf::from(s),
        _ => home_dir().join(default_sub),
    }
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/"))
}

pub fn config_file() -> PathBuf {
    xdg_dir("XDG_CONFIG_HOME", ".config")
        .join("wallpaper-tui")
        .join("config.json")
}

pub fn state_file() -> PathBuf {
    xdg_dir("XDG_STATE_HOME", ".local/state")
        .join("wallpaper-tui")
        .join("state.json")
}

/// ``XDG_CACHE_HOME/wallpaper-tui/thumbs`` — chafa-free thumbnail cache.
pub fn preview_cache_dir() -> PathBuf {
    xdg_dir("XDG_CACHE_HOME", ".cache")
        .join("wallpaper-tui")
        .join("thumbs")
}

pub fn tint_dir() -> PathBuf {
    state_file()
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join("tint")
}

pub fn tint_state_file() -> PathBuf {
    tint_dir().join("current.json")
}

/// One declarative output's defaults (Nix is the source of truth).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputConfig {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default = "default_mode")]
    pub mode: String,
    #[serde(default = "default_color")]
    pub fill_color: String,
}

fn default_mode() -> String {
    "fill".to_string()
}
fn default_color() -> String {
    DEFAULT_COLOR.to_string()
}

/// The declarative, read-only config written by the Nix module.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub wallpaper_folder: String,
    #[serde(default = "default_true")]
    pub recursive: bool,
    #[serde(default)]
    pub current_output: String,
    #[serde(default = "default_transition_type")]
    pub transition_type: String,
    #[serde(default = "default_transition_duration")]
    pub transition_duration: f64,
    #[serde(default)]
    pub outputs: std::collections::BTreeMap<String, OutputConfig>,
}

fn default_true() -> bool {
    true
}
fn default_transition_type() -> String {
    "grow".to_string()
}
fn default_transition_duration() -> f64 {
    1.0
}

impl Config {
    /// Read the declarative config; missing/garbage → a permissive default.
    pub fn load() -> Self {
        Self::load_from(config_file())
    }

    pub fn load_from(path: PathBuf) -> Self {
        match fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }
}

/// One output's runtime override (writable; ``None`` fields = inherit).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputOverride {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_color: Option<String>,
}

/// Writable runtime state: per-output overrides only.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub outputs: std::collections::BTreeMap<String, OutputOverride>,
}

impl State {
    pub fn load() -> Self {
        Self::load_from(state_file())
    }

    pub fn load_from(path: PathBuf) -> Self {
        match fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> anyhow::Result<()> {
        self.save_to(state_file())
    }

    pub fn save_to(&self, path: PathBuf) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).ok();
        }
        let mut json = serde_json::to_string_pretty(self)?;
        json.push('\n');
        fs::write(&path, json).with_context(|| format!("saving state to {}", path.display()))
    }
}

/// The effective merge of declarative defaults and runtime overrides for one
/// output. Override wins; empty strings fall back to the declarative value;
/// the final fallback is ``fill`` / ``DEFAULT_COLOR``.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Effective {
    pub path: String,
    pub mode: String,
    pub fill_color: String,
}

pub fn effective_output<'a>(config: &'a Config, state: &'a State, output: &str) -> Effective {
    let decl = config.outputs.get(output);
    let over = state.outputs.get(output);
    let pick = |ov: Option<&str>, dv: Option<&str>, fallback: &str| -> String {
        let ov = ov.filter(|s| !s.is_empty());
        let dv = dv.filter(|s| !s.is_empty());
        ov.or(dv).unwrap_or(fallback).to_string()
    };
    Effective {
        path: pick(
            over.and_then(|o| o.path.as_deref()),
            decl.and_then(|d| d.path.as_deref()),
            "",
        ),
        mode: pick(
            over.and_then(|o| o.mode.as_deref()),
            decl.map(|d| d.mode.as_str()),
            "fill",
        ),
        fill_color: pick(
            over.and_then(|o| o.fill_color.as_deref()),
            decl.map(|d| d.fill_color.as_str()),
            DEFAULT_COLOR,
        ),
    }
}

/// ``{accent, source_path}`` persisted under ``tint/current.json`` so the
/// expensive SVG-tree regen can be skipped when the accent is unchanged.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TintState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
}

impl TintState {
    pub fn load() -> Self {
        Self::load_from(tint_state_file())
    }

    pub fn load_from(path: PathBuf) -> Self {
        match fs::read_to_string(path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> anyhow::Result<()> {
        fs::create_dir_all(tint_dir()).ok();
        self.save_to(tint_state_file())
    }

    pub fn save_to(&self, path: PathBuf) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).ok();
        }
        let mut json = serde_json::to_string_pretty(self)?;
        json.push('\n');
        fs::write(&path, json).with_context(|| format!("saving tint state to {}", path.display()))
    }
}
