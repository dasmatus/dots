//! Integration tests for the pure geometry helpers in `dots_snip::geometry`.

use dots_snip::geometry::{clamp_to_output, format_grim_geometry, to_global, Rect};

fn rect(x: i32, y: i32, w: i32, h: i32) -> Rect {
    Rect { x, y, w, h }
}

#[test]
fn format_grim_geometry_basic() {
    assert_eq!(
        format_grim_geometry(&rect(10, 20, 300, 400)),
        "10,20,300x400"
    );
}

#[test]
fn format_grim_geometry_zero_origin() {
    assert_eq!(
        format_grim_geometry(&rect(0, 0, 1920, 1080)),
        "0,0,1920x1080"
    );
}

#[test]
fn clamp_fully_inside_is_unchanged() {
    let r = rect(100, 100, 200, 200);
    assert_eq!(clamp_to_output(r, 0, 0, 1920, 1080), r);
}

#[test]
fn clamp_partially_off_top_left() {
    // Rect extends 50px above/left of the 0,0 origin.
    let clamped = clamp_to_output(rect(-50, -50, 200, 200), 0, 0, 1920, 1080);
    assert_eq!(clamped, rect(0, 0, 150, 150));
}

#[test]
fn clamp_partially_off_bottom_right() {
    // 1920x1080 output; rect overshoots the bottom-right corner by 40px.
    let clamped = clamp_to_output(rect(1800, 1000, 160, 120), 0, 0, 1920, 1080);
    assert_eq!(clamped, rect(1800, 1000, 120, 80));
}

#[test]
fn clamp_fully_outside_collapses_to_zero_area() {
    let clamped = clamp_to_output(rect(-500, -500, 100, 100), 0, 0, 1920, 1080);
    assert_eq!(clamped, rect(0, 0, 0, 0));
}

#[test]
fn clamp_respects_nonzero_output_offset() {
    // Second monitor at (1920, 0) of size 1280x800.
    let clamped = clamp_to_output(rect(1900, -10, 100, 100), 1920, 0, 1280, 800);
    assert_eq!(clamped, rect(1920, 0, 80, 90));
}

#[test]
fn to_global_shifts_by_monitor_offset_and_clamps() {
    // Monitor at (1920, 0), 1280x800. A window-local rect (10, 20, 100, 100)
    // becomes global (1930, 20, 100, 100) — fully inside, so unchanged after
    // clamping.
    let g = to_global(rect(10, 20, 100, 100), Some((1920, 0, 1280, 800)));
    assert_eq!(g, rect(1930, 20, 100, 100));
}

#[test]
fn to_global_clamps_overshoot_to_monitor_extents() {
    // Window-local rect at x=1240 (monitor is 1280 wide) overshoots the right
    // edge by 60px once shifted by the 1920 offset → 3160..3260, clamped to
    // 3160..3200, i.e. a 40px-wide sliver.
    let g = to_global(rect(1240, 0, 100, 100), Some((1920, 0, 1280, 800)));
    assert_eq!(g, rect(3160, 0, 40, 100));
}

#[test]
fn to_global_none_returns_rect_unchanged() {
    let r = rect(42, 42, 200, 200);
    assert_eq!(to_global(r, None), r);
}
