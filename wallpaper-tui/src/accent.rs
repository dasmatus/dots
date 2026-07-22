//! Wallpaper → accent extraction. ``rgb_to_hls``/``hls_to_rgb`` are a faithful
//! port of CPython's ``colorsys`` (HLS, same parameter order: h, l, s) so the
//! accent hue matches the Python extractor and the ported tests pass.
//!
//! The extractor downsamples to 64×64, drops near-black/white/low-saturation
//! pixels, buckets the rest by hue (16 bins), and picks the bucket with the
//! largest saturation-weighted population. The winning hue is remapped to a
//! fixed target lightness/saturation (0.62/0.55) so the accent is always a
//! usable UI color; dark/light companions share h and s at L=0.40 / L=0.78.

use std::path::Path;

use crate::config::{DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT};

/// (h, l, s) — hue, lightness, saturation, all in 0..=1. Port of
/// ``colorsys.rgb_to_hls``.
pub fn rgb_to_hls(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let l = (minc + maxc) / 2.0;
    if minc == maxc {
        return (0.0, l, 0.0);
    }
    let s = if l <= 0.5 {
        (maxc - minc) / (maxc + minc)
    } else {
        (maxc - minc) / (2.0 - maxc - minc)
    };
    let rc = (maxc - r) / (maxc - minc);
    let gc = (maxc - g) / (maxc - minc);
    let bc = (maxc - b) / (maxc - minc);
    let h = if r == maxc {
        bc - gc
    } else if g == maxc {
        2.0 + rc - bc
    } else {
        4.0 + gc - rc
    };
    let h = (h / 6.0).rem_euclid(1.0);
    (h, l, s)
}

/// Port of ``colorsys._v`` (the hue → value segment helper).
fn v_tri(m1: f64, m2: f64, mut hue: f64) -> f64 {
    hue = hue.rem_euclid(1.0);
    if hue < 1.0 / 6.0 {
        m1 + (m2 - m1) * hue * 6.0
    } else if hue < 0.5 {
        m2
    } else if hue < 2.0 / 3.0 {
        m1 + (m2 - m1) * (2.0 / 3.0 - hue) * 6.0
    } else {
        m1
    }
}

/// Port of ``colorsys.hls_to_rgb(h, l, s)``. Returns (r, g, b) in 0..=1.
pub fn hls_to_rgb(h: f64, l: f64, s: f64) -> (f64, f64, f64) {
    if s == 0.0 {
        return (l, l, l);
    }
    let m2 = if l <= 0.5 {
        l * (1.0 + s)
    } else {
        l + s - l * s
    };
    let m1 = 2.0 * l - m2;
    (
        v_tri(m1, m2, h + 1.0 / 3.0),
        v_tri(m1, m2, h),
        v_tri(m1, m2, h - 1.0 / 3.0),
    )
}

/// Parse ``#rrggbb`` → (r, g, b) bytes.
pub fn hex_to_rgb(hex: &str) -> (u8, u8, u8) {
    let h = hex.trim_start_matches('#');
    let r = u8::from_str_radix(&h[0..2], 16).unwrap_or(0);
    let g = u8::from_str_radix(&h[2..4], 16).unwrap_or(0);
    let b = u8::from_str_radix(&h[4..6], 16).unwrap_or(0);
    (r, g, b)
}

/// ``(r, g, b)`` bytes (0..=255) → ``#rrggbb``.
pub fn rgb_to_hex(rgb: (u8, u8, u8)) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2)
}

/// ``#rrggbb`` → (h, l, s).
pub fn hex_to_hls(hex: &str) -> (f64, f64, f64) {
    let (r, g, b) = hex_to_rgb(hex);
    rgb_to_hls(r as f64 / 255.0, g as f64 / 255.0, b as f64 / 255.0)
}

/// ``(h, l, s)`` → ``#rrggbb``. Rounds each channel via Python's
/// ``int(round(c * 255))`` (half away from zero — matches the C
/// ``round``/``rint`` path for non-half values, which is all the remap ever
/// produces).
pub fn hls_to_hex(h: f64, l: f64, s: f64) -> String {
    let (r, g, b) = hls_to_rgb(h, l, s);
    rgb_to_hex((clamp_byte(r), clamp_byte(g), clamp_byte(b)))
}

fn clamp_byte(c: f64) -> u8 {
    let v = (c * 255.0).round();
    if v < 0.0 {
        0
    } else if v > 255.0 {
        255
    } else {
        v as u8
    }
}

/// ``(accent, accent_dark, accent_light)`` from a wallpaper path. Any decode
/// error or empty-pixel image falls back to the Tokyonight-blue family.
pub fn extract_accent(path: &str) -> (String, String, String) {
    match try_extract_accent(path) {
        Some(triple) => triple,
        None => (
            DEFAULT_ACCENT.to_string(),
            DEFAULT_ACCENT_DARK.to_string(),
            DEFAULT_ACCENT_LIGHT.to_string(),
        ),
    }
}

fn try_extract_accent(path: &str) -> Option<(String, String, String)> {
    let dyn_img = image::open(Path::new(path)).ok()?;
    // Aspect-preserving 64×64 downsample (no-op when the image is already ≤64).
    let thumb = dyn_img.thumbnail(64, 64).to_rgb8();

    // 16 hue bins: [weight, hue_sum, count].
    let mut bins: [(f64, f64, u32); 16] = [(0.0, 0.0, 0); 16];
    for px in thumb.pixels() {
        let (r, g, b) = (px.0[0] as f64, px.0[1] as f64, px.0[2] as f64);
        let (h, l, s) = rgb_to_hls(r / 255.0, g / 255.0, b / 255.0);
        if !(0.1..=0.9).contains(&l) || s < 0.2 {
            continue;
        }
        let bin = (h * 16.0).floor() as usize;
        let bin = if bin >= 16 { 15 } else { bin };
        bins[bin].0 += s;
        bins[bin].1 += h;
        bins[bin].2 += 1;
    }
    let best = bins
        .iter()
        .enumerate()
        .filter(|(_, b)| b.2 > 0)
        .max_by(|a, b| {
            a.1 .0
                .partial_cmp(&b.1 .0)
                .unwrap_or(std::cmp::Ordering::Equal)
        })?;
    let &(_, h_sum, cnt) = best.1;
    let hue = h_sum / cnt as f64;
    Some((
        hls_to_hex(hue, 0.62, 0.55),
        hls_to_hex(hue, 0.40, 0.55),
        hls_to_hex(hue, 0.78, 0.55),
    ))
}
