//! Design tokens: the Tokyo Night defaults resolved from `rust/palette.json`,
//! partial `theme.canvas` overrides, and the generated stylesheet.

use beamenu_canvas::palette::PALETTE;
use beamenu_canvas::theme::{hex_to_rgba, stylesheet, CanvasTheme, PRIMARY_BUTTON_TEXT};

#[test]
fn defaults_match_the_tokyo_night_palette() {
    let theme = CanvasTheme::default();
    assert_eq!(theme.font_ui, "Manrope");
    assert_eq!(theme.font_mono, "JetBrains Mono");
    assert_eq!(theme.bg, "#1a1b26");
    assert_eq!(theme.panel_gradient_start, "#1f2335");
    assert_eq!(theme.panel_gradient_end, "#1a1b26");
    assert_eq!(theme.border, "#3b4261");
    assert_eq!(theme.border_strong, "#414868");
    assert_eq!(theme.text, "#c0caf5");
    assert_eq!(theme.muted, "#737aa2");
    assert_eq!(theme.accent, "#7aa2f7");
    assert_eq!(PRIMARY_BUTTON_TEXT, "#15161e");
}

#[test]
fn defaults_are_the_palette_file_verbatim() {
    let theme = CanvasTheme::default();
    assert_eq!(theme.font_ui, PALETTE.fonts.canvas_ui);
    assert_eq!(theme.font_mono, PALETTE.fonts.canvas_mono);
    assert_eq!(theme.bg, PALETTE.colors.bg);
    assert_eq!(theme.panel_gradient_start, PALETTE.colors.bg_dark);
    assert_eq!(theme.panel_gradient_end, PALETTE.colors.bg);
    assert_eq!(theme.border, PALETTE.colors.selection);
    assert_eq!(theme.border_strong, PALETTE.colors.border);
    assert_eq!(theme.text, PALETTE.colors.fg);
    assert_eq!(theme.muted, PALETTE.colors.muted);
    assert_eq!(theme.accent, PALETTE.accent_fallback);
    assert_eq!(PRIMARY_BUTTON_TEXT, PALETTE.colors.bg_darker);
}

#[test]
fn deserializes_from_empty_object_using_defaults() {
    let theme: CanvasTheme = serde_json::from_str("{}").expect("defaults apply");
    assert_eq!(theme, CanvasTheme::default());
}

#[test]
fn partial_override_keeps_the_rest_at_default() {
    let theme: CanvasTheme =
        serde_json::from_str(r##"{"accent": "#ff00ff"}"##).expect("partial theme parses");
    assert_eq!(theme.accent, "#ff00ff");
    assert_eq!(theme.font_ui, "Manrope");
    assert_eq!(theme.bg, "#1a1b26");
}

#[test]
fn hex_to_rgba_converts_six_digit_hex() {
    assert_eq!(hex_to_rgba("#7fd6c2", 0.2), "rgba(127, 214, 194, 0.2)");
}

#[test]
fn hex_to_rgba_ignores_trailing_alpha_channel() {
    assert_eq!(hex_to_rgba("#7fd6c2ff", 0.2), "rgba(127, 214, 194, 0.2)");
}

#[test]
fn hex_to_rgba_falls_back_to_black_on_malformed_input() {
    assert_eq!(hex_to_rgba("not-a-colour", 0.5), "rgba(0, 0, 0, 0.5)");
}

#[test]
fn stylesheet_embeds_the_focus_ring_at_binding_alpha() {
    let theme = CanvasTheme::default();
    let css = stylesheet(&theme);
    assert!(css.contains("rgba(122, 162, 247, 0.2)"));
}

#[test]
fn stylesheet_embeds_every_token() {
    let theme = CanvasTheme::default();
    let css = stylesheet(&theme);
    assert!(css.contains("Manrope"));
    assert!(css.contains("JetBrains Mono"));
    assert!(css.contains("#1a1b26"));
    assert!(css.contains("#1f2335"));
    assert!(css.contains("#3b4261"));
    assert!(css.contains("#414868"));
    assert!(css.contains("#c0caf5"));
    assert!(css.contains("#737aa2"));
    assert!(css.contains("#7aa2f7"));
    assert!(css.contains(PRIMARY_BUTTON_TEXT));
}

#[test]
fn stylesheet_reflects_a_custom_accent() {
    let mut theme = CanvasTheme::default();
    theme.accent = "#ff8800".to_string();
    let css = stylesheet(&theme);
    assert!(css.contains("#ff8800"));
    assert!(!css.contains("#7aa2f7"));
}
