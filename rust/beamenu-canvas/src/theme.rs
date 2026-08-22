//! Design tokens for the canvas's one host-enforced stylesheet.
//!
//! `CanvasTheme` reads `theme.canvas` in `beamenu/config.json`
//! (`crate::config::Config`); every field is serde-defaulted to the binding
//! design values from the task brief, so a missing or partial `canvas`
//! object still gives the intended look. [`stylesheet`] is the ONLY place
//! CSS text gets built — workers never supply CSS or HTML, only the typed
//! [`crate::component::Component`] trees this stylesheet then dresses.

use serde::{Deserialize, Serialize};

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
    "Manrope".into()
}
fn default_font_mono() -> String {
    "JetBrains Mono".into()
}
fn default_bg() -> String {
    "#0d1013".into()
}
fn default_panel_start() -> String {
    "#171c22".into()
}
fn default_panel_end() -> String {
    "#0d1013".into()
}
fn default_border() -> String {
    "#1e252c".into()
}
fn default_border_strong() -> String {
    "#262e36".into()
}
fn default_text() -> String {
    "#e6ebef".into()
}
fn default_muted() -> String {
    "#5b6672".into()
}
fn default_accent() -> String {
    "#7fd6c2".into()
}

/// Primary button text colour — fixed, not derived from `accent`, so the
/// button stays high-contrast whatever `accent` is configured to.
pub const PRIMARY_BUTTON_TEXT: &str = "#08110e";

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
input, select, textarea {{
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
  background: var(--accent);
  color: var(--button-text);
  border: none;
  border-radius: 6px;
  padding: 8px 14px;
  font-family: var(--font-ui);
  cursor: pointer;
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
