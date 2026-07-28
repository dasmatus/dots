//! Full-redraw contract for hyprmon's `Driver` loop.
//!
//! `tui::run` drives the engine with a custom `Driver` loop (the same shape
//! the other TUI apps use) instead of `App::run`, specifically so it can call
//! `abstracttui::app::request_full_redraw()` before every `Driver::turn()`.
//! That makes each draw a complete console rewrite (Claude-Code style): the
//! diff presenter poisons its previous-frame model and re-emits every cell
//! that frame, wrapped in DEC-2026 sync output, so any terminal/model desync
//! self-heals on the next draw.
//!
//! `tui::run` needs a real tty + `hyprctl`, so it is not directly callable
//! from a test. This test mounts a trivial view against the same `Driver` +
//! `CaptureTerm` path and pins the redraw contract the loop relies on: an
//! unchanged frame is normally suppressed to zero bytes by the diff, but the
//! same unchanged state preceded by `request_full_redraw()` emits a full
//! non-empty frame again.

use abstracttui::app::{self, App as Engine, Driver, RunConfig};
use abstracttui::prelude::*;
use abstracttui::testing::CaptureTerm;

#[test]
fn request_full_redraw_re_emits_an_unchanged_frame() {
    let size = Size::new(40, 8);

    let mut engine = Engine::new(size);
    engine
        .mount(|cx| {
            let n = cx.signal("hyprmon".to_string());
            Element::new()
                .child(dyn_view(LayoutStyle::fill(), move || {
                    text(format!("hello {n}", n = n.get()))
                }))
                .build()
        })
        .expect("mount");

    let mut term = CaptureTerm::new(size);
    let cfg = RunConfig {
        probe: false,
        ..RunConfig::default()
    };
    let mut driver = Driver::new(&mut engine, &mut term, cfg).expect("driver");

    // Discard the enter bytes so only frame emissions are measured.
    let _enter = term.take_bytes();

    // Turn 1: the initial frame paints a full screen of cells.
    let turn1 = driver.turn(&mut engine, &mut term).expect("turn 1");
    assert!(turn1.emitted, "initial frame emits bytes: {turn1:?}");
    let frame1 = term.take_bytes();
    assert!(!frame1.is_empty(), "initial frame is non-empty");
    let screen_after_initial = screen_text(&term, size);

    // Idle turn, no change, no full-redraw request: the diff suppresses
    // byte-identical cells, so the unchanged frame emits nothing.
    let idle = driver.turn(&mut engine, &mut term).expect("idle turn");
    assert!(
        term.take_bytes().is_empty(),
        "idle unchanged frame emits zero bytes: {idle:?}"
    );

    // Same unchanged state, but `request_full_redraw()` is set first — exactly
    // what `tui::run` does every draw. The presenter re-anchors and the diff
    // re-emits every cell this frame.
    app::request_full_redraw();
    let turn3 = driver.turn(&mut engine, &mut term).expect("redraw turn");
    assert!(turn3.emitted, "forced-redraw turn emits bytes: {turn3:?}");
    let frame3 = term.take_bytes();
    assert!(
        !frame3.is_empty(),
        "forced full redraw emits a non-empty frame"
    );

    // The full rewrite reproduces the same screen: re-emitting every cell
    // overwrites whatever the terminal held (the desync-healing property).
    let screen_after_redraw = screen_text(&term, size);
    assert_eq!(
        screen_after_initial, screen_after_redraw,
        "full redraw reproduces the same screen content"
    );
    let _ = (frame1, frame3);
}

/// Concatenate the modeled screen's cell text, one row per line.
fn screen_text(term: &CaptureTerm, size: Size) -> String {
    let mut out = String::new();
    for y in 0..size.h {
        for x in 0..size.w {
            if let Some(cell) = term.screen().cell(x, y) {
                out.push_str(cell.display());
            }
        }
        out.push('\n');
    }
    out
}
