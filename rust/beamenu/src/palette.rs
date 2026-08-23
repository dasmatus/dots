//! The system palette, compiled in from `rust/palette.json` — the same file
//! `nix/home/beamenu.nix` reads with `builtins.fromJSON`, so the Nix-rendered
//! config and these Rust fallbacks can never drift apart.
//!
//! Base colours are 6-digit `#RRGGBB`; alpha is applied per consumer at the
//! seam via [`Alpha`]'s two-hex-digit suffixes, because bemenu wants
//! `#RRGGBBAA` while other surfaces re-apply opacity themselves.

use std::sync::LazyLock;

use serde::Deserialize;

/// Raw bytes of `rust/palette.json`; the path climbs out of the crate dir,
/// which is why flake/packages.nix roots the src fileset at `rust/`.
const RAW: &str = include_str!("../../palette.json");

/// The palette, parsed once on first use. The file is committed and gated by
/// the `palette-eval` flake check, so a parse failure is a build bug.
pub static PALETTE: LazyLock<Palette> = LazyLock::new(|| {
    serde_json::from_str(RAW).expect("rust/palette.json is valid; palette-eval gates it")
});

/// Everything `rust/palette.json` declares.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Palette {
    pub colors: Colors,
    /// Accent used before a wallpaper-derived accent exists.
    pub accent_fallback: String,
    pub alpha: Alpha,
    pub fonts: Fonts,
    pub beamenu: BeamenuMetrics,
}

/// Tokyo Night neutrals and ramp, 6-digit `#RRGGBB`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Colors {
    pub bg: String,
    pub bg_dark: String,
    pub bg_darker: String,
    pub fg: String,
    pub fg_dark: String,
    pub muted: String,
    pub border: String,
    pub selection: String,
    pub blue: String,
    pub cyan: String,
    pub green: String,
    pub magenta: String,
    pub red: String,
    pub yellow: String,
    pub orange: String,
    pub dim: String,
}

/// Two-hex-digit alpha suffixes appended to a base colour at the seam.
#[derive(Debug, Clone, Deserialize)]
pub struct Alpha {
    pub panel: String,
    pub heading: String,
    pub opaque: String,
}

/// Font roles. `canvas_ui`/`canvas_mono` name beamenu-canvas's deliberately
/// distinct typography; the divergence is a declared choice, not a second
/// hardcoded list.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fonts {
    pub ui: String,
    pub mono: String,
    pub size: u32,
    pub canvas_ui: String,
    pub canvas_mono: String,
}

/// beamenu's layout metrics — app-scoped, but duplicated between the Nix
/// options and the serde defaults in exactly the way the colours were, so
/// they live in the same file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeamenuMetrics {
    pub lines: u32,
    pub width_factor: f32,
    pub icon_size: u32,
    pub line_height: u32,
    pub search_height: u32,
    pub radius: u32,
}

/// The two theme slots derived from an accent: `selected_background`
/// (accent + opaque alpha) and `heading` (accent + heading alpha), in that
/// order. The same concatenation lives in `nix/home/beamenu.nix` for the
/// configured path — serde defaults cannot read sibling fields, so the rule
/// exists once per side and both sides are tested.
#[must_use]
pub fn accent_slots(accent: &str) -> (String, String) {
    (
        format!("{accent}{}", PALETTE.alpha.opaque),
        format!("{accent}{}", PALETTE.alpha.heading),
    )
}
