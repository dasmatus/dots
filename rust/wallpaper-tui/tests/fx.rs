//! Unit tests for the wallpaper TUI animation overlay: the crossfade curve
//! (0→1 over the duration, `EaseOut`), the env gate, the re-triggerable one-shot
//! opacity ramp on `Fx`, and the `blend_bitmap` pixel math.

use std::time::Duration;

use abstracttui::anim::Clock;
use abstracttui::base::Rgba;
use abstracttui::gfx::Bitmap;

use wallpaper_tui::fx::{animations_enabled, blend_bitmap, crossfade_curve, Fx};

#[test]
fn crossfade_curve_rises_to_one_then_settles() {
    let curve = crossfade_curve(Clock::fixed(), 150);
    assert!(curve.now(0).abs() < 1e-6, "starts invisible");
    assert!(
        (curve.now(150) - 1.0).abs() < 1e-6,
        "fully visible at duration"
    );
    let mid = curve.now(75);
    assert!(
        mid > 0.0 && mid < 1.0,
        "mid-fade is between 0 and 1, got {mid}"
    );
    // EaseOut front-loads: the eased value at the midpoint is past 0.5.
    assert!(
        mid > 0.5,
        "EaseOut should be past halfway at the midpoint, got {mid}"
    );
}

#[test]
fn animations_enabled_respects_env() {
    std::env::set_var("DOTS_NO_ANIM", "1");
    assert!(!animations_enabled());
    std::env::remove_var("DOTS_NO_ANIM");
    assert!(animations_enabled());
}

#[test]
fn crossfade_retrigger_fires_and_settles_to_one() {
    let mut fx = Fx::new(Clock::fixed());
    // Idle: opacity pinned at 1.0.
    fx.tick();
    assert!(
        (fx.crossfade_opacity() - 1.0).abs() < 1e-6,
        "idle opacity is 1.0"
    );
    // Fire at t=0, then advance to the midpoint — opacity is in (0, 1).
    fx.retarget_crossfade_force();
    fx.advance(Duration::from_millis(75));
    let mid = fx.crossfade_opacity();
    assert!(
        mid > 0.0 && mid < 1.0,
        "mid-fade opacity in (0,1), got {mid}"
    );
    // After the full duration, the one-shot clears and opacity pins at 1.0.
    fx.advance(Duration::from_millis(75));
    assert!(
        (fx.crossfade_opacity() - 1.0).abs() < 1e-6,
        "settled to 1.0"
    );
    // Re-triggering after settle restarts the fade from 0.
    fx.retarget_crossfade_force();
    fx.advance(Duration::from_millis(1));
    assert!(
        fx.crossfade_opacity() < mid,
        "re-trigger restarts the fade from near-zero"
    );
}

#[test]
fn blend_bitmap_lerps_from_bg_to_image_by_opacity() {
    let px: Vec<Rgba> = vec![Rgba::rgb(255, 0, 0); 4];
    let bmp = Bitmap::from_pixels(2, 2, px).expect("4 px");
    let bg = Rgba::rgb(0, 0, 0);
    // opacity 0 → fully bg (black).
    let faded = blend_bitmap(&bmp, bg, 0.0);
    assert_eq!(faded.pixels()[0], bg);
    // opacity 1 → fully the source (red).
    let full = blend_bitmap(&bmp, bg, 1.0);
    assert_eq!(full.pixels()[0], Rgba::rgb(255, 0, 0));
    // opacity 0.5 → midpoint (≈127,0,0).
    let half = blend_bitmap(&bmp, bg, 0.5);
    let p = half.pixels()[0];
    assert!(
        (i16::from(p.r) - 127).abs() <= 1,
        "red midpoint ~127, got {}",
        p.r
    );
}
