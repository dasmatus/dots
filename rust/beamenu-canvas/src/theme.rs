//! Design tokens for the canvas's one host-enforced stylesheet.
//!
//! `CanvasTheme` reads `theme.canvas` in `beamenu/config.json`
//! (`crate::config::Config`); every field is serde-defaulted from
//! `rust/palette.json` (Tokyo Night), so a missing or partial `canvas`
//! object still gives the intended look. [`stylesheet`] is the ONLY place
//! CSS text gets built — workers never supply CSS or HTML, only the typed
//! [`crate::component::Component`] trees this stylesheet then dresses.

use serde::{Deserialize, Serialize};

use crate::palette::PALETTE;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanvasTheme {
    #[serde(default = "default_font_ui")]
    pub font_ui: String,
    #[serde(default = "default_font_mono")]
    pub font_mono: String,
    #[serde(default = "default_bg")]
    pub bg: String,
    #[serde(default = "default_panel_start")]
    pub panel_gradient_start: String,
    #[serde(default = "default_panel_end")]
    pub panel_gradient_end: String,
    #[serde(default = "default_border")]
    pub border: String,
    #[serde(default = "default_border_strong")]
    pub border_strong: String,
    #[serde(default = "default_text")]
    pub text: String,
    #[serde(default = "default_muted")]
    pub muted: String,
    #[serde(default = "default_accent")]
    pub accent: String,
}

fn default_font_ui() -> String {
    PALETTE.fonts.canvas_ui.clone()
}
fn default_font_mono() -> String {
    PALETTE.fonts.canvas_mono.clone()
}
fn default_bg() -> String {
    PALETTE.colors.bg.clone()
}
fn default_panel_start() -> String {
    PALETTE.colors.bg_dark.clone()
}
fn default_panel_end() -> String {
    PALETTE.colors.bg.clone()
}
/// Hairline border: Tokyo Night's `selection`, the dimmer of its pair —
/// `border_strong` below takes the brighter `border` slot.
fn default_border() -> String {
    PALETTE.colors.selection.clone()
}
fn default_border_strong() -> String {
    PALETTE.colors.border.clone()
}
fn default_text() -> String {
    PALETTE.colors.fg.clone()
}
fn default_muted() -> String {
    PALETTE.colors.muted.clone()
}
fn default_accent() -> String {
    PALETTE.accent_fallback.clone()
}

/// Primary button text colour — fixed, not derived from `accent`, so the
/// button stays high-contrast whatever `accent` is configured to. Mirrors
/// the palette file's `colors.bgDarker`; a const cannot read the `LazyLock`,
/// so `tests/theme.rs` pins the two together instead.
pub const PRIMARY_BUTTON_TEXT: &str = "#15161e";

/// Alpha of the 3px focus ring around a focused form control.
const FOCUS_RING_ALPHA: f32 = 0.2;

impl Default for CanvasTheme {
    fn default() -> Self {
        serde_json::from_str("{}").expect("every CanvasTheme field has a serde default")
    }
}

/// Convert a `#RRGGBB` (or `#RRGGBBAA`, alpha ignored) hex colour to a CSS
/// `rgba()` string at `alpha`. A malformed token in config.json falls back
/// to black rather than panicking — a bad theme value should look wrong, not
/// crash the canvas.
#[must_use]
pub fn hex_to_rgba(hex: &str, alpha: f32) -> String {
    let hex = hex.trim_start_matches('#');
    let (r, g, b) = if matches!(hex.len(), 6 | 8) {
        (
            u8::from_str_radix(&hex[0..2], 16).unwrap_or(0),
            u8::from_str_radix(&hex[2..4], 16).unwrap_or(0),
            u8::from_str_radix(&hex[4..6], 16).unwrap_or(0),
        )
    } else {
        (0, 0, 0)
    };
    format!("rgba({r}, {g}, {b}, {alpha})")
}

/// Render the single stylesheet injected into every canvas page via
/// `WebKitUserContentManager`.
#[must_use]
pub fn stylesheet(theme: &CanvasTheme) -> String {
    let focus_ring = hex_to_rgba(&theme.accent, FOCUS_RING_ALPHA);
    format!(
        r"
:root {{
  --font-ui: '{font_ui}', sans-serif;
  --font-mono: '{font_mono}', monospace;
  --bg: {bg};
  --panel-start: {panel_start};
  --panel-end: {panel_end};
  --border: {border};
  --border-strong: {border_strong};
  --text: {text};
  --muted: {muted};
  --accent: {accent};
  --focus-ring: {focus_ring};
  --button-text: {button_text};
}}
* {{ box-sizing: border-box; }}
html, body {{
  margin: 0; padding: 0; min-height: 100%;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-ui);
}}
.panel {{
  background: linear-gradient(180deg, var(--panel-start), var(--panel-end));
  border: 1px solid var(--border);
  min-height: 100%;
}}
pre, code, .log {{ font-family: var(--font-mono); }}
.muted {{ color: var(--muted); }}
input:not([type='checkbox']):not([type='radio']), select, textarea {{
  /* WebKitGTK renders form controls via the native GTK theme engine
     unless `appearance` is disabled, which silently ignores the
     `background`/`color`/`border` below — unlike Safari/macOS WebKit,
     where the same rule needs no such override. Checkboxes/radios are
     excluded: their native GTK check/dot indicator is worth keeping over
     an unstyled box with no checked-state affordance at all. */
  appearance: none;
  -webkit-appearance: none;
  background: var(--panel-end);
  color: var(--text);
  border: 1px solid var(--border-strong);
  border-radius: 6px;
  padding: 6px 8px;
  font-family: var(--font-ui);
}}
input:focus, select:focus, textarea:focus {{
  outline: none;
  box-shadow: 0 0 0 3px var(--focus-ring);
  border-color: var(--accent);
}}
button.primary {{
  /* Same native-GTK-theme override as the `input`/`select`/`textarea`
     rule above — without it WebKitGTK paints the button chrome itself
     and ignores `background` below. */
  appearance: none;
  -webkit-appearance: none;
  background: var(--accent);
  color: var(--button-text);
  border: none;
  border-radius: 6px;
  padding: 8px 14px;
  font-family: var(--font-ui);
  cursor: pointer;
}}
/* The launcher's preview pane. The column sits on a strip of the panel that
   bemenu already painted and drew a hairline down, so it adds no border and
   no background of its own: anything opaque here would be a second panel
   stacked on the first. */
#column {{ padding: 14px 16px 0 16px; gap: 10px; }}
.preview-head {{ flex: 0 0 auto; }}
.preview-title {{
  font-size: 15px; font-weight: 600;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}}
.preview-subtitle {{
  font-size: 12px; margin-top: 2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}}
.preview-body {{
  flex: 1 1 auto; min-height: 0;
  overflow-y: auto; overflow-x: hidden;
}}
.preview-note {{ font-size: 12px; margin: 8px 0; }}
.preview-image {{ display: flex; align-items: center; justify-content: center; }}
.preview-image img {{
  max-width: 100%; max-height: 100%;
  object-fit: contain; border-radius: 8px;
}}
.preview-text {{
  font-size: 12px; line-height: 1.45; margin: 0;
  white-space: pre-wrap; word-break: break-word;
}}
.preview-listing {{ list-style: none; margin: 0; padding: 0; font-size: 13px; }}
.preview-listing li {{
  padding: 2px 0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}}
.preview-listing li.dir {{ color: var(--accent); }}
/* A previewed document gets the whole body. The frame is sandboxed and
   opaque-origin (see crate::preview::document_html), and paints its own
   background, so it is given a light one rather than left to inherit a dark
   panel a page never designed against. */
.preview-doc {{
  width: 100%; height: 100%;
  border: 0; border-radius: 8px; background: #ffffff;
}}
.preview-meta {{
  flex: 0 0 auto; margin: 0;
  padding: 10px 0; border-top: 1px solid var(--border);
  font-size: 12px;
}}
.preview-meta-row {{ display: flex; gap: 12px; padding: 2px 0; }}
.preview-meta dt {{ color: var(--muted); flex: 0 0 34%; }}
.preview-meta dd {{
  margin: 0; flex: 1 1 auto;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}}
.ansi-bold {{ font-weight: 700; }}
.ansi-fg-black {{ color: #1a1d21; }}
.ansi-fg-red {{ color: #e0685f; }}
.ansi-fg-green {{ color: var(--accent); }}
.ansi-fg-yellow {{ color: #e0c15f; }}
.ansi-fg-blue {{ color: #6fa8e0; }}
.ansi-fg-magenta {{ color: #b98fe0; }}
.ansi-fg-cyan {{ color: #6fd6d1; }}
.ansi-fg-white {{ color: var(--text); }}
.ansi-fg-bright-black {{ color: var(--muted); }}
.ansi-fg-bright-red {{ color: #f08a82; }}
.ansi-fg-bright-green {{ color: #a3e8d8; }}
.ansi-fg-bright-yellow {{ color: #f0d98a; }}
.ansi-fg-bright-blue {{ color: #94c2ea; }}
.ansi-fg-bright-magenta {{ color: #d3b3ea; }}
.ansi-fg-bright-cyan {{ color: #9be6e1; }}
.ansi-fg-bright-white {{ color: #ffffff; }}
",
        font_ui = theme.font_ui,
        font_mono = theme.font_mono,
        bg = theme.bg,
        panel_start = theme.panel_gradient_start,
        panel_end = theme.panel_gradient_end,
        border = theme.border,
        border_strong = theme.border_strong,
        text = theme.text,
        muted = theme.muted,
        accent = theme.accent,
        focus_ring = focus_ring,
        button_text = PRIMARY_BUTTON_TEXT,
    )
}
