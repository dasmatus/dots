//! Animation-math tests using abstracttui's fixed clock for determinism.

use std::time::Duration;

use abstracttui::anim::Clock;

use dots_installer::fx::{animations_enabled, ease_ratio, shake_at, ScreenFx};

#[test]
fn ease_ratio_eases_out_and_clamps() {
    let clock = Clock::fixed();
    let r = ease_ratio(clock, 0.0, 1.0, 200);
    // EaseOut: 0 at start, 1 at/after duration, > 0.5 at the midpoint.
    assert!(r.now(0).abs() < 1e-6);
    assert!((r.now(200) - 1.0).abs() < 1e-6);
    assert!(r.now(100) > 0.5);
}

#[test]
fn shake_settles_to_zero_after_duration() {
    let clock = Clock::fixed();
    let s = shake_at(clock, 120);
    assert!(s.now(0).abs() < 1e-6);
    assert!(s.now(121).abs() < 1e-6);
    // Mid-flight the shake is nonzero (it actually shakes).
    assert!(s.now(60).abs() > 0.0);
}

#[test]
fn animations_enabled_respects_env() {
    std::env::set_var("DOTS_NO_ANIM", "1");
    assert!(!animations_enabled());
    std::env::remove_var("DOTS_NO_ANIM");
    assert!(animations_enabled());
}

#[test]
fn progress_retarget_eases_toward_target() {
    let mut fx = ScreenFx::new(Clock::fixed());
    // Retarget to 1.0; at t=0 the eased value is still ~0. EaseOut doesn't
    // start slow, it front-loads, so by the midpoint it's already > 0.5.
    fx.retarget_progress_force(1.0);
    fx.advance(Duration::ZERO);
    assert!(
        fx.progress_r().abs() < 1e-6,
        "starts at 0: {}",
        fx.progress_r()
    );
    fx.advance(Duration::from_millis(80));
    assert!(fx.progress_r() > 0.5, "midpoint > 0.5: {}", fx.progress_r());
    fx.advance(Duration::from_millis(160));
    assert!(
        (fx.progress_r() - 1.0).abs() < 1e-6,
        "lands at 1: {}",
        fx.progress_r()
    );
}

#[test]
fn shake_force_fires_and_settles() {
    let mut fx = ScreenFx::new(Clock::fixed());
    fx.shake_force();
    fx.advance(Duration::from_millis(60));
    assert!(
        fx.shake_x().abs() > 0,
        "shaking mid-flight: {}",
        fx.shake_x()
    );
    // After SHAKE_DUR (120ms) the one-shot clears and the offset is 0.
    fx.advance(Duration::from_millis(80));
    assert_eq!(fx.shake_x(), 0, "settled: {}", fx.shake_x());
}

#[test]
fn screen_retarget_eases_to_target() {
    let mut fx = ScreenFx::new(Clock::fixed());
    fx.retarget_screen_force(1.0);
    fx.advance(Duration::ZERO);
    assert!(fx.screen_x().abs() < 1e-6, "starts at 0: {}", fx.screen_x());
    fx.advance(Duration::from_millis(180));
    assert!(
        (fx.screen_x() - 1.0).abs() < 1e-6,
        "lands at 1: {}",
        fx.screen_x()
    );
}
