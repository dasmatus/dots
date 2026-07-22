//! extract_accent — the wallpaper → accent-color extractor. Ports
//! ``test_extract_accent.py``. Synthetic flat-color images pin the expected
//! hue; the extractor's remap to a fixed target lightness/saturation means we
//! assert on *hue* (and that the result is bright, not muddy) rather than
//! exact hexes.

mod common;

use tempfile::tempdir;
use wallpaper_tui::accent::{extract_accent, hex_to_hls};
use wallpaper_tui::config::{DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT};

use common::{make_image, make_image_with_patch};

fn hue_of(hexstr: &str) -> f64 {
    hex_to_hls(hexstr).0
}

fn light_of(hexstr: &str) -> f64 {
    hex_to_hls(hexstr).1
}

fn is_bright_enough(hexstr: &str) -> bool {
    // accent should be remapped to L≈0.62, never near-black.
    (0.45..0.72).contains(&light_of(hexstr))
}

#[test]
fn solid_red_yields_red_hue() {
    let d = tempdir().unwrap();
    let p = d.path().join("red.png");
    make_image(&p, (220, 30, 30), 64);
    let (accent, _dark, _light) = extract_accent(p.to_str().unwrap());
    let h = hue_of(&accent);
    assert!(
        !(0.04..=0.96).contains(&h),
        "red wallpaper -> hue {h}, expected ~0"
    );
    assert!(is_bright_enough(&accent), "accent not bright: {accent}");
}

#[test]
fn solid_green_yields_green_hue() {
    let d = tempdir().unwrap();
    let p = d.path().join("green.png");
    make_image(&p, (40, 200, 60), 64);
    let (accent, _, _) = extract_accent(p.to_str().unwrap());
    let h = hue_of(&accent);
    assert!(
        h > 0.28 && h < 0.38,
        "green wallpaper -> hue {h}, expected ~0.33"
    );
}

#[test]
fn solid_blue_yields_blue_hue() {
    let d = tempdir().unwrap();
    let p = d.path().join("blue.png");
    make_image(&p, (60, 120, 230), 64);
    let (accent, _, _) = extract_accent(p.to_str().unwrap());
    let h = hue_of(&accent);
    assert!(
        h > 0.55 && h < 0.66,
        "blue wallpaper -> hue {h}, expected ~0.6"
    );
}

#[test]
fn shades_share_hue() {
    let d = tempdir().unwrap();
    let p = d.path().join("magenta.png");
    make_image(&p, (220, 40, 200), 64);
    let (accent, dark, light) = extract_accent(p.to_str().unwrap());
    let (ha, hd, hl) = (hue_of(&accent), hue_of(&dark), hue_of(&light));
    // all three companions share the accent hue (within bucket resolution).
    assert!(ha.max(hd).max(hl) - ha.min(hd).min(hl) < 0.07);
    // and span lightness: dark < accent < light.
    let (la, ld, ll) = (light_of(&accent), light_of(&dark), light_of(&light));
    assert!(ld < la && la < ll);
}

#[test]
fn grayscale_falls_back_to_default() {
    let d = tempdir().unwrap();
    let p = d.path().join("gray.png");
    make_image(&p, (128, 128, 128), 64);
    let (accent, dark, light) = extract_accent(p.to_str().unwrap());
    assert_eq!(accent, DEFAULT_ACCENT);
    assert_eq!(dark, DEFAULT_ACCENT_DARK);
    assert_eq!(light, DEFAULT_ACCENT_LIGHT);
}

#[test]
fn near_black_falls_back_to_default() {
    let d = tempdir().unwrap();
    let p = d.path().join("black.png");
    make_image(&p, (5, 5, 5), 64);
    let triple = extract_accent(p.to_str().unwrap());
    assert_eq!(triple.0, DEFAULT_ACCENT);
    assert_eq!(triple.1, DEFAULT_ACCENT_DARK);
    assert_eq!(triple.2, DEFAULT_ACCENT_LIGHT);
}

#[test]
fn missing_path_falls_back() {
    let triple = extract_accent("/no/such/file.png");
    assert_eq!(triple.0, DEFAULT_ACCENT);
    assert_eq!(triple.1, DEFAULT_ACCENT_DARK);
    assert_eq!(triple.2, DEFAULT_ACCENT_LIGHT);
}

#[test]
fn dominant_vibrant_beats_small_saturated_patch() {
    // A mostly-blue image with a small red patch: blue should win because the
    // extractor weights by saturation×frequency, not by raw saturation alone.
    let d = tempdir().unwrap();
    let p = d.path().join("mostly_blue.png");
    make_image_with_patch(&p, (60, 120, 230), (220, 30, 30));
    let (accent, _, _) = extract_accent(p.to_str().unwrap());
    let h = hue_of(&accent);
    assert!(
        h > 0.55 && h < 0.66,
        "dominant blue should win, got hue {h} ({accent})"
    );
}
