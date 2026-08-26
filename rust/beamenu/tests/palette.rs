//! The compiled-in palette: `rust/palette.json` parsed once, and the theme
//! defaults `src/config.rs` derives from it. The eight launcher slots must
//! resolve from the palette, and a non-default accent must move both
//! accent-derived slots (`selected_background`, `heading`) with it.

use beamenu::config::{Config, Theme};
use beamenu::palette::{accent_slots, PALETTE};

#[test]
fn palette_json_parses_to_tokyo_night() {
    assert_eq!(PALETTE.colors.bg, "#1a1b26");
    assert_eq!(PALETTE.colors.bg_dark, "#1f2335");
    assert_eq!(PALETTE.colors.bg_darker, "#15161e");
    assert_eq!(PALETTE.colors.fg, "#c0caf5");
    assert_eq!(PALETTE.colors.muted, "#737aa2");
    assert_eq!(PALETTE.colors.border, "#414868");
    assert_eq!(PALETTE.colors.selection, "#3b4261");
    assert_eq!(PALETTE.accent_fallback, "#7aa2f7");
    assert_eq!(PALETTE.alpha.panel, "f2");
    assert_eq!(PALETTE.alpha.heading, "ee");
    assert_eq!(PALETTE.alpha.opaque, "ff");
    assert_eq!(PALETTE.fonts.ui, "Lilex Nerd Font");
    assert_eq!(PALETTE.fonts.size, 12);
}

#[test]
fn theme_default_resolves_every_slot_from_the_palette() {
    let theme = Theme::default();
    assert_eq!(theme.background, "#1a1b26f2");
    assert_eq!(theme.foreground, "#c0caf5ff");
    assert_eq!(theme.muted, "#737aa2ff");
    assert_eq!(theme.selected_background, "#7aa2f7ff");
    assert_eq!(theme.selected_foreground, "#15161eff");
    assert_eq!(theme.border, "#414868ff");
    assert_eq!(theme.heading, "#7aa2f7ee");
    assert_eq!(theme.font, "Lilex Nerd Font 12");
    assert_eq!(theme.accent, "#7aa2f7");
}

#[test]
fn a_non_default_accent_moves_both_derived_slots() {
    let (selected_background, heading) = accent_slots("#8fb8f0");
    assert_eq!(selected_background, "#8fb8f0ff");
    assert_eq!(heading, "#8fb8f0ee");
    let stock = Theme::default();
    assert_ne!(selected_background, stock.selected_background);
    assert_ne!(heading, stock.heading);
}

/// `Config::default()`'s metric fields (`default_lines` et al., in
/// `src/config.rs`) currently read `PALETTE.beamenu.*` directly, so this
/// comparison is a tautology today — it cannot be made to fail in-crate,
/// since `include_str!` embeds `palette.json` at compile time and there is
/// no fixture to vary it against. What it guards is *drift*: if a later
/// change hardcodes one of these defaults as a literal instead of deriving
/// it from `PALETTE`, editing `rust/palette.json`'s `beamenu.*` values would
/// then move only one side of this assertion, and the test would fail.
#[test]
fn config_metric_defaults_do_not_drift_from_the_compiled_in_palette() {
    let config = Config::default();
    assert_eq!(config.lines, PALETTE.beamenu.lines);
    assert_eq!(config.icon_size, PALETTE.beamenu.icon_size);
    assert_eq!(config.line_height, PALETTE.beamenu.line_height);
    assert_eq!(config.search_height, PALETTE.beamenu.search_height);
    assert_eq!(config.preview_width, PALETTE.beamenu.preview_width);
    assert_eq!(config.radius, PALETTE.beamenu.radius);
    assert!((config.width_factor - PALETTE.beamenu.width_factor).abs() < f32::EPSILON);
}
