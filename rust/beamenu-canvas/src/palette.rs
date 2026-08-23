//! The subset of `rust/palette.json` this crate reads, compiled in via
//! `include_str!` — the same file `nix/home/beamenu.nix` reads with
//! `builtins.fromJSON` and `rust/beamenu/src/palette.rs` carries in full.
//! A trimmed duplicate rather than a dependency, for the same reason
//! `src/config.rs` duplicates the loader: the two crates stay unlinked.

use std::sync::LazyLock;

use serde::Deserialize;

/// Raw bytes of `rust/palette.json`; flake/packages.nix roots the src
/// fileset at `rust/` so this path resolves inside the sandbox too.
const RAW: &str = include_str!("../../palette.json");

/// Parsed once on first use; the committed file is gated by the
/// `palette-eval` flake check, so a parse failure is a build bug.
pub static PALETTE: LazyLock<Palette> = LazyLock::new(|| {
    serde_json::from_str(RAW).expect("rust/palette.json is valid; palette-eval gates it")
});

/// The palette keys the canvas reads; serde ignores the rest of the file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Palette {
    pub colors: Colors,
    /// Accent used before a wallpaper-derived accent exists.
    pub accent_fallback: String,
    pub fonts: Fonts,
    pub beamenu: Metrics,
}

/// Neutral slots, 6-digit `#RRGGBB` — the canvas applies alpha in CSS.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Colors {
    pub bg: String,
    pub bg_dark: String,
    pub bg_darker: String,
    pub fg: String,
    pub muted: String,
    pub border: String,
    pub selection: String,
}

/// The canvas's deliberately distinct typography roles.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fonts {
    pub canvas_ui: String,
    pub canvas_mono: String,
}

/// Launcher metrics shared with `rust/beamenu`; only `widthFactor` is read
/// here, to size the layer-shell surface like the launcher panel.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub width_factor: f32,
}
