//! Declarative knobs, written by `nix/home/beamenu.nix`.
//!
//! Home Manager renders this to `$XDG_CONFIG_HOME/beamenu/config.json`. Every
//! field has a default, so a missing or unparseable file still gives a
//! working launcher rather than no launcher at all.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::palette::{accent_slots, PALETTE};

/// Colours are bemenu hex strings, `#RRGGBB` or `#RRGGBBAA`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Theme {
    pub background: String,
    pub foreground: String,
    pub muted: String,
    pub selected_background: String,
    pub selected_foreground: String,
    pub border: String,
    pub heading: String,
    pub font: String,
    /// Accent for the currently-active element: the highlighted result row
    /// and the active filter pill (`BM_COLOR_HIGHLIGHTED_BG` on the C side;
    /// `BM_COLOR_HIGHLIGHTED_FG` stays `selected_foreground`, unchanged).
    ///
    /// `#[serde(default)]` on this field alone, unlike its siblings: a
    /// config.json written before this field existed is otherwise missing
    /// `theme.accent`, which would fail all of `Theme`'s deserialization
    /// (none of its other fields have a per-field default) and silently
    /// reset every theme colour to `Theme::default()`, not just this one.
    #[serde(default = "default_accent")]
    pub accent: String,
}

fn default_accent() -> String {
    PALETTE.accent_fallback.clone()
}

impl Default for Theme {
    /// Every slot resolved from `rust/palette.json` (Tokyo Night):
    /// panel `bg` + panel alpha, text `fg`, `muted`, `border`, and the two
    /// accent-derived slots from [`accent_slots`] over `accentFallback`.
    /// Text drawn on the accent fill uses `bgDarker`, keeping the
    /// dark-on-accent contrast the launcher always had.
    ///
    /// This is the fallback for a missing or unparseable config.json, not
    /// the configured path — `nix/home/beamenu.nix` renders the same file
    /// into config.json, so the two can only drift if the palette schema
    /// itself changes.
    fn default() -> Self {
        let p = &*PALETTE;
        let (selected_background, heading) = accent_slots(&p.accent_fallback);
        Self {
            background: format!("{}{}", p.colors.bg, p.alpha.panel),
            foreground: format!("{}{}", p.colors.fg, p.alpha.opaque),
            muted: format!("{}{}", p.colors.muted, p.alpha.opaque),
            selected_background,
            selected_foreground: format!("{}{}", p.colors.bg_darker, p.alpha.opaque),
            border: format!("{}{}", p.colors.border, p.alpha.opaque),
            heading,
            font: format!("{} {}", p.fonts.ui, p.fonts.size),
            accent: default_accent(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub theme: Theme,
    /// Rows shown at once. The panel height follows from this.
    #[serde(default = "default_lines")]
    pub lines: u32,
    /// Fraction of the output width the panel occupies.
    #[serde(default = "default_width_factor")]
    pub width_factor: f32,
    /// Icon edge length in pixels.
    #[serde(default = "default_icon_size")]
    pub icon_size: u32,
    /// List row height in pixels.
    #[serde(default = "default_line_height")]
    pub line_height: u32,
    /// Search row height in pixels.
    #[serde(default = "default_search_height")]
    pub search_height: u32,
    /// Panel corner radius in pixels.
    #[serde(default = "default_radius")]
    pub radius: u32,
    /// Terminal used to run desktop entries marked `Terminal=true`.
    #[serde(default = "default_terminal")]
    pub terminal: String,
    /// File manager used by the "Reveal in file manager" action.
    #[serde(default = "default_file_manager")]
    pub file_manager: String,
    /// Provider ids to leave out entirely.
    #[serde(default)]
    pub disabled: Vec<String>,
}

fn default_lines() -> u32 {
    PALETTE.beamenu.lines
}
fn default_width_factor() -> f32 {
    PALETTE.beamenu.width_factor
}
fn default_icon_size() -> u32 {
    PALETTE.beamenu.icon_size
}
fn default_line_height() -> u32 {
    PALETTE.beamenu.line_height
}
fn default_search_height() -> u32 {
    PALETTE.beamenu.search_height
}
fn default_radius() -> u32 {
    PALETTE.beamenu.radius
}
/// Terminal used for desktop entries marked `Terminal=true`.
///
/// `nix/home/beamenu.nix` normally supplies this, so the fallback only matters
/// when config.json is missing or unreadable. `$TERMINAL` is the closest thing
/// to a convention for "the terminal this user wants"; `xterm` is the last
/// resort because it is the one name a system with any X or Wayland terminal
/// stack is most likely to resolve.
fn default_terminal() -> String {
    std::env::var("TERMINAL").unwrap_or_else(|_| "xterm".into())
}

/// File manager used by the "Reveal in file manager" action.
///
/// Defaults to `$FILE_MANAGER`, then to `xdg-open`, which resolves through the
/// desktop's own MIME association for `inode/directory` rather than naming a
/// particular file manager.
fn default_file_manager() -> String {
    std::env::var("FILE_MANAGER").unwrap_or_else(|_| "xdg-open".into())
}

impl Default for Config {
    fn default() -> Self {
        serde_json::from_str("{}").expect("every Config field has a serde default")
    }
}

impl Config {
    /// Load from `path`, falling back to defaults on any failure.
    #[must_use]
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }
}

/// `$XDG_CONFIG_HOME/beamenu`, falling back to `~/.config/beamenu`.
#[must_use]
pub fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map_or_else(
            || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"),
            PathBuf::from,
        )
        .join("beamenu")
}

/// `$XDG_STATE_HOME/beamenu`, falling back to `~/.local/state/beamenu`.
#[must_use]
pub fn state_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map_or_else(
            || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"),
            PathBuf::from,
        )
        .join("beamenu")
}
