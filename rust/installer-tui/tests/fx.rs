//! Animation-math tests using abstracttui's fixed clock for determinism.

use abstracttui::anim::Clock;

use dots_installer::fx::{animations_enabled, ease_ratio, shake_at};

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
