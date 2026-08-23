//! Tiny duplicate of `rust/beamenu/src/config.rs`'s loader.
//!
//! Deliberately NOT a dependency on the `beamenu` crate — the task brief is
//! explicit about that. `beamenu-canvas` only needs `width_factor` (to size
//! the layer-shell surface like the launcher panel) and `theme.canvas`
//! (`crate::theme::CanvasTheme`, this crate's own design tokens), so it
//! duplicates just the loader shape rather than linking the whole launcher
//! crate.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::theme::CanvasTheme;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Theme {
    #[serde(default)]
    pub canvas: CanvasTheme,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub theme: Theme,
    #[serde(default = "default_width_factor")]
    pub width_factor: f32,
}

/// Kept in step with `rust/beamenu/src/config.rs::default_width_factor` and
/// `nix/home/beamenu.nix`'s `widthFactor` option default.
fn default_width_factor() -> f32 {
    0.375
}

impl Default for Config {
    fn default() -> Self {
        serde_json::from_str("{}").expect("every Config field has a serde default")
    }
}

impl Config {
    /// Load from `path`, falling back to defaults on any failure — a missing
    /// or unparseable file still gives a working canvas, just an undressed
    /// one.
    #[must_use]
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }
}

/// `$XDG_CONFIG_HOME/beamenu`, falling back to `~/.config/beamenu` — the same
/// directory `rust/beamenu/src/config.rs::config_dir` resolves, since both
/// crates read the same `config.json`.
#[must_use]
pub fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map_or_else(
            || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"),
            PathBuf::from,
        )
        .join("beamenu")
}
