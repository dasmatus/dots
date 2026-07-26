//! Wallpaper → accent extraction. ``rgb_to_hls``/``hls_to_rgb`` are a faithful
//! port of `CPython`'s ``colorsys`` (HLS, same parameter order: h, l, s) so the
//! accent hue matches the Python extractor and the ported tests pass.
//!
//! Two palette backends are available:
//!
//! * ``Internal`` — in-process thumbnail + hue-bucket extractor (Pillow logic
//!   ported to Rust). Fast, deterministic, and testable without external tools.
//! * ``Pywal`` — shells out to ``wal -i <wallpaper> -n -q -s`` and reads the
//!   generated ``~/.cache/wal/colors.json``. Uses ``colors.color5`` as the accent
//!   and derives dark/light variants from it. Falls back to ``Internal`` if
//!   ``wal`` is missing or fails.
//!
//! The internal extractor downsamples to 64×64, drops near-black/white/low-saturation
//! pixels, buckets the rest by hue (16 bins), and picks the bucket with the
//! largest saturation-weighted population. The winning hue is remapped to a
//! fixed target lightness/saturation (0.62/0.55) so the accent is always a
//! usable UI color; dark/light companions share h and s at L=0.40 / L=0.78.

use std::fmt;
use std::path::Path;
use std::process::Command;
use std::str::FromStr;

use crate::config::{DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT};

/// Palette backend used to derive the wallpaper accent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TintBackend {
    /// In-process hue-bucket extractor.
    Internal,
    /// Pywal-generated palette; ``wal`` must be on PATH.
    #[default]
    Pywal,
}

impl fmt::Display for TintBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TintBackend::Internal => write!(f, "internal"),
            TintBackend::Pywal => write!(f, "pywal"),
        }
    }
}

impl FromStr for TintBackend {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "internal" => Ok(TintBackend::Internal),
            "pywal" => Ok(TintBackend::Pywal),
            _ => Err(format!("unknown tint backend: {s}")),
        }
    }
}

/// (h, l, s) — hue, lightness, saturation, all in 0..=1. Port of
/// ``colorsys.rgb_to_hls``.
#[must_use]
pub fn rgb_to_hls(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let l = f64::midpoint(minc, maxc);
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
#[must_use]
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
#[must_use]
pub fn hex_to_rgb(hex: &str) -> (u8, u8, u8) {
    let h = hex.trim_start_matches('#');
    let r = u8::from_str_radix(&h[0..2], 16).unwrap_or(0);
    let g = u8::from_str_radix(&h[2..4], 16).unwrap_or(0);
    let b = u8::from_str_radix(&h[4..6], 16).unwrap_or(0);
    (r, g, b)
}

/// ``(r, g, b)`` bytes (0..=255) → ``#rrggbb``.
#[must_use]
pub fn rgb_to_hex(rgb: (u8, u8, u8)) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2)
}

/// ``#rrggbb`` → (h, l, s).
#[must_use]
pub fn hex_to_hls(hex: &str) -> (f64, f64, f64) {
    let (r, g, b) = hex_to_rgb(hex);
    rgb_to_hls(
        f64::from(r) / 255.0,
        f64::from(g) / 255.0,
        f64::from(b) / 255.0,
    )
}

/// ``(h, l, s)`` → ``#rrggbb``. Rounds each channel via Python's
/// ``int(round(c * 255))`` (half away from zero — matches the C
/// ``round``/``rint`` path for non-half values, which is all the remap ever
/// produces).
#[must_use]
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

/// Derive dark/light variants from an accent by keeping hue/saturation.
/// Dark is pushed below the accent and light above it, clamped to a usable
/// UI range, so the ordering ``dark < accent < light`` always holds even
/// when the input accent is very dark or very light.
#[must_use]
pub fn accent_shades(accent: &str) -> (String, String, String) {
    let (h, l, s) = hex_to_hls(accent);
    let dark_l = (l - 0.25).max(0.15).min(l - 0.02);
    let light_l = (l + 0.15).min(0.90).max(l + 0.02);
    (
        accent.to_string(),
        hls_to_hex(h, dark_l, s),
        hls_to_hex(h, light_l, s),
    )
}

/// Parse pywal's ``colors.json`` and return the ``color5`` accent family.
/// Exposed for unit testing the parser without shelling out to ``wal``.
#[must_use]
pub fn parse_pywal_colors(text: &str) -> Option<(String, String, String)> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let accent = v.get("colors")?.get("color5")?.as_str()?.to_string();
    if !accent.starts_with('#') || accent.len() != 7 {
        return None;
    }
    Some(accent_shades(&accent))
}

/// ``(accent, accent_dark, accent_light)`` from a wallpaper path using the
/// chosen backend. On failure, falls back to the Tokyonight-blue family.
#[must_use]
pub fn extract_accent(path: &str, backend: TintBackend) -> (String, String, String) {
    let triple = match backend {
        TintBackend::Internal => try_extract_accent_internal(path),
        TintBackend::Pywal => extract_accent_pywal(path),
    };
    triple.unwrap_or_else(|| {
        (
            DEFAULT_ACCENT.to_string(),
            DEFAULT_ACCENT_DARK.to_string(),
            DEFAULT_ACCENT_LIGHT.to_string(),
        )
    })
}

fn try_extract_accent_internal(path: &str) -> Option<(String, String, String)> {
    let dyn_img = image::open(Path::new(path)).ok()?;
    // Aspect-preserving 64×64 downsample (no-op when the image is already ≤64).
    let thumb = dyn_img.thumbnail(64, 64).to_rgb8();

    // 16 hue bins: [weight, hue_sum, count].
    let mut bins: [(f64, f64, u32); 16] = [(0.0, 0.0, 0); 16];
    for px in thumb.pixels() {
        let (r, g, b) = (f64::from(px.0[0]), f64::from(px.0[1]), f64::from(px.0[2]));
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
    let hue = h_sum / f64::from(cnt);
    Some((
        hls_to_hex(hue, 0.62, 0.55),
        hls_to_hex(hue, 0.40, 0.55),
        hls_to_hex(hue, 0.78, 0.55),
    ))
}

/// Run pywal against the wallpaper and parse ``colors.color5`` from its cache.
/// Any failure returns ``None`` so the caller can fall back.
fn extract_accent_pywal(path: &str) -> Option<(String, String, String)> {
    let status = Command::new("wal")
        .args(["-i", path, "-n", "-q", "-s"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()?;
    if !status.success() {
        return None;
    }

    let cache = crate::config::xdg_dir("XDG_CACHE_HOME", ".cache")
        .join("wal")
        .join("colors.json");
    let text = std::fs::read_to_string(cache).ok()?;
    parse_pywal_colors(&text)
}
