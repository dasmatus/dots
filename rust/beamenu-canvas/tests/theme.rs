//! Design tokens: the binding defaults from the task brief, partial
//! `theme.canvas` overrides, and the generated stylesheet.

use beamenu_canvas::theme::{hex_to_rgba, stylesheet, CanvasTheme, PRIMARY_BUTTON_TEXT};

#[test]
fn defaults_match_the_binding_design_values() {
    let theme = CanvasTheme::default();
    assert_eq!(theme.font_ui, "Manrope");
    assert_eq!(theme.font_mono, "JetBrains Mono");
    assert_eq!(theme.bg, "#0d1013");
    assert_eq!(theme.panel_gradient_start, "#171c22");
    assert_eq!(theme.panel_gradient_end, "#0d1013");
    assert_eq!(theme.border, "#1e252c");
    assert_eq!(theme.border_strong, "#262e36");
    assert_eq!(theme.text, "#e6ebef");
    assert_eq!(theme.muted, "#5b6672");
    assert_eq!(theme.accent, "#7fd6c2");
    assert_eq!(PRIMARY_BUTTON_TEXT, "#08110e");
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
    assert_eq!(theme.bg, "#0d1013");
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
    assert!(css.contains("rgba(127, 214, 194, 0.2)"));
}

#[test]
fn stylesheet_embeds_every_token() {
    let theme = CanvasTheme::default();
    let css = stylesheet(&theme);
    assert!(css.contains("Manrope"));
    assert!(css.contains("JetBrains Mono"));
    assert!(css.contains("#0d1013"));
    assert!(css.contains("#171c22"));
    assert!(css.contains("#1e252c"));
    assert!(css.contains("#262e36"));
    assert!(css.contains("#e6ebef"));
    assert!(css.contains("#5b6672"));
    assert!(css.contains("#7fd6c2"));
    assert!(css.contains(PRIMARY_BUTTON_TEXT));
}

#[test]
fn stylesheet_reflects_a_custom_accent() {
    let mut theme = CanvasTheme::default();
    theme.accent = "#ff8800".to_string();
    let css = stylesheet(&theme);
    assert!(css.contains("#ff8800"));
    assert!(!css.contains("#7fd6c2"));
}
