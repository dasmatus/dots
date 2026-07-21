//! Pure geometry helpers — no I/O, no Tauri, fully unit-testable.
//!
//! `grim -g` takes a geometry string `"x,y,WxH"` in Hyprland *logical*
//! coordinates. A fullscreen Tauri window's CSS pixels live in that same
//! logical space, so a selection rect coming from the webview maps straight
//! onto `grim -g` once it is shifted by the focused monitor's layout offset.

use serde::Deserialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// Clamp `rect` so it lies entirely within the output box
/// `(ox, oy) .. (ox + ow, oy + oh)`. Assumes non-negative `w`/`h`.
#[must_use]
pub fn clamp_to_output(rect: Rect, ox: i32, oy: i32, ow: i32, oh: i32) -> Rect {
    let x = rect.x.max(ox).min(ox + ow);
    let y = rect.y.max(oy).min(oy + oh);
    let x2 = (rect.x + rect.w).max(ox).min(ox + ow);
    let y2 = (rect.y + rect.h).max(oy).min(oy + oh);
    Rect {
        x,
        y,
        w: (x2 - x).max(0),
        h: (y2 - y).max(0),
    }
}

/// Shift a window-local rect into global compositor coordinates by adding the
/// focused monitor's `(x, y)` offset, then clamp to that monitor's
/// `(width, height)` extents. `mon = None` means the monitor layout could not
/// be read — the rect is returned unchanged as a best-effort fallback.
#[must_use]
pub fn to_global(rect: Rect, mon: Option<(i32, i32, i32, i32)>) -> Rect {
    match mon {
        Some((mx, my, mw, mh)) => {
            let shifted = Rect {
                x: rect.x + mx,
                y: rect.y + my,
                ..rect
            };
            clamp_to_output(shifted, mx, my, mw, mh)
        }
        None => rect,
    }
}

/// Format a rect as a `grim -g` geometry string: `"x,y,WxH"`.
#[must_use]
pub fn format_grim_geometry(rect: &Rect) -> String {
    format!("{},{},{}x{}", rect.x, rect.y, rect.w, rect.h)
}
