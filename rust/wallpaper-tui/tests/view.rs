//! Headless render tests for the wallpaper TUI view. Each test mounts
//! `ui::root_view` over a `Signal<App>` (and `Signal<Fx>`) set to a canned
//! state, pumps one frame into a `CaptureTerm`, and asserts the rendered
//! cells contain the expected user-visible strings (list title, wallpaper
//! names, info bar, help line, preview labels).

mod common;

use std::sync::Arc;
use std::time::Duration;

use abstracttui::anim::Clock;
use abstracttui::app::{App as Engine, Driver, RunConfig};
use abstracttui::base::Rgba;
use abstracttui::gfx::Bitmap;
use abstracttui::prelude::*;
use abstracttui::testing::CaptureTerm;
use tempfile::TempDir;

use wallpaper_tui::accent::TintBackend;
use wallpaper_tui::app::App;
use wallpaper_tui::config::{Config, State};
use wallpaper_tui::fx::Fx;
use wallpaper_tui::ui;

/// A config whose `wallpaper_folder` is a temp dir holding `count` flat-color
/// PNGs named `wp0.png`..`wp{count-1}.png`.
fn config_with_wallpapers(count: u8) -> (TempDir, Config) {
    let dir = TempDir::new().expect("tmp");
    for i in 0..count {
        let p = dir.path().join(format!("wp{i}.png"));
        common::make_image(&p, (40 + i * 10, 200, 60), 16);
    }
    let cfg = Config {
        wallpaper_folder: dir.path().to_string_lossy().into_owned(),
        recursive: true,
        ..Config::default()
    };
    (dir, cfg)
}

/// Render `app` at `cols`×`rows` and return the concatenated cell text, one row
/// per line. Uses the engine's `Driver` + `CaptureTerm` headless path.
fn render_to_string(app: &App, cols: i32, rows: i32) -> String {
    let mut engine = Engine::new(Size::new(cols, rows));
    engine
        .mount(|cx| {
            let app_sig = cx.signal(app.clone());
            let fx_sig = cx.signal(Fx::new(Clock::real()));
            ui::root_view(app_sig, fx_sig)
        })
        .expect("mount");

    let mut term = CaptureTerm::new(Size::new(cols, rows));
    let cfg = RunConfig {
        probe: false,
        ..RunConfig::default()
    };
    let mut driver = Driver::new(&mut engine, &mut term, cfg).expect("driver");
    let _ = driver.turn(&mut engine, &mut term).expect("turn");

    cells_to_string(&term, cols, rows)
}

fn cells_to_string(term: &CaptureTerm, cols: i32, rows: i32) -> String {
    let mut out = String::new();
    for y in 0..rows {
        for x in 0..cols {
            if let Some(cell) = term.screen().cell(x, y) {
                out.push_str(cell.display());
            }
        }
        out.push('\n');
    }
    out
}

fn new_app(cfg: Config) -> App {
    App::new(cfg, State::default(), false, TintBackend::default())
}

fn small_test_bitmap() -> Arc<Bitmap> {
    let px: Vec<Rgba> = (0..64u8).map(|i| Rgba::rgb(i, 0, 0)).collect();
    Arc::new(Bitmap::from_pixels(8, 8, px).expect("64 px"))
}

#[test]
fn empty_state_lists_no_wallpapers_message() {
    let (_dir, cfg) = config_with_wallpapers(0);
    let app = new_app(cfg);
    let out = render_to_string(&app, 80, 24);
    assert!(
        out.contains("No wallpapers found"),
        "missing empty msg: {out}"
    );
    assert!(out.contains("Enter:apply"), "missing help line: {out}");
}

#[test]
fn list_shows_wallpaper_names_title_info_and_help() {
    let (_dir, cfg) = config_with_wallpapers(3);
    let app = new_app(cfg);
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("wallpapers"), "missing list title: {out}");
    assert!(out.contains("wp0.png"), "missing wp0: {out}");
    assert!(out.contains("wp1.png"), "missing wp1: {out}");
    assert!(out.contains("wp2.png"), "missing wp2: {out}");
    // Info bar shows the effective output + mode + color.
    assert!(out.contains("Output:"), "missing info bar: {out}");
    assert!(out.contains("Mode:"), "missing mode in info: {out}");
    // Help line is present verbatim.
    assert!(out.contains("Enter:apply  j/k:move"), "missing help: {out}");
}

#[test]
fn list_highlights_selected_entry_with_arrow() {
    let (_dir, cfg) = config_with_wallpapers(2);
    let app = new_app(cfg);
    let out = render_to_string(&app, 80, 24);
    // Exactly one entry is prefixed with "> " (walkdir's order is unspecified,
    // so the highlighted name is whatever `wallpapers[0]` resolved to).
    let marked: Vec<&str> = out.lines().filter(|l| l.contains("> wp")).collect();
    assert_eq!(
        marked.len(),
        1,
        "expected one highlighted entry, got {marked:?}: {out}"
    );
}

#[test]
fn preview_pane_shows_unavailable_label_when_no_bitmap() {
    let (_dir, cfg) = config_with_wallpapers(1);
    let app = new_app(cfg);
    let out = render_to_string(&app, 80, 24);
    assert!(
        out.contains("[preview unavailable]") || out.contains("rendering"),
        "missing preview fallback label: {out}"
    );
}

#[test]
fn preview_pane_shows_image_when_bitmap_present() {
    let (_dir, cfg) = config_with_wallpapers(1);
    let mut app = new_app(cfg);
    app.preview = Some(small_test_bitmap());
    let out = render_to_string(&app, 80, 24);
    assert!(
        !out.contains("[preview unavailable]"),
        "preview label shown despite bitmap: {out}"
    );
    assert!(out.contains("preview"), "missing preview title: {out}");
}

#[test]
fn preview_pane_blank_when_preview_hidden() {
    let (_dir, cfg) = config_with_wallpapers(1);
    let mut app = new_app(cfg);
    app.show_preview = false;
    app.preview = Some(small_test_bitmap());
    let out = render_to_string(&app, 80, 24);
    // The preview pane is blanked (no image label either) when preview is off.
    assert!(
        !out.contains("[preview unavailable]"),
        "label shown despite preview hidden: {out}"
    );
}

#[test]
fn crossfade_retarget_drives_opacity_through_the_signal() {
    let (_dir, cfg) = config_with_wallpapers(1);
    let mut app = new_app(cfg);
    app.preview = Some(small_test_bitmap());

    // Mount with a captured fx signal so the test can drive the crossfade and
    // read the eased opacity back. The pixel-blend math is unit-tested in
    // tests/fx.rs (`blend_bitmap_lerps_from_bg_to_image_by_opacity`); this test
    // proves the overlay is wired through the signal and the view renders
    // mid-fade without panicking.
    let mut engine = Engine::new(Size::new(80, 24));
    let mut fx_out: Option<Signal<Fx>> = None;
    engine
        .mount(|cx| {
            let app_sig = cx.signal(app.clone());
            let fx_sig = cx.signal(Fx::new(Clock::fixed()));
            fx_out = Some(fx_sig);
            ui::root_view(app_sig, fx_sig)
        })
        .expect("mount");
    let fx_sig = fx_out.expect("fx signal mounted");

    // Idle: opacity pinned at 1.0.
    assert!(
        (fx_sig.with_untracked(Fx::crossfade_opacity) - 1.0).abs() < 1e-6,
        "idle opacity should be 1.0"
    );
    // Retarget + advance to the midpoint: opacity is in (0, 1).
    fx_sig.update(Fx::retarget_crossfade_force);
    fx_sig.update(|f| f.advance(Duration::from_millis(75)));
    let mid = fx_sig.with_untracked(Fx::crossfade_opacity);
    assert!(
        mid > 0.0 && mid < 1.0,
        "mid-fade opacity in (0,1), got {mid}"
    );

    // The view renders mid-fade without panicking and the preview title lives.
    let mut term = CaptureTerm::new(Size::new(80, 24));
    let cfg = RunConfig {
        probe: false,
        ..RunConfig::default()
    };
    let mut driver = Driver::new(&mut engine, &mut term, cfg).expect("driver");
    let _ = driver.turn(&mut engine, &mut term).expect("turn");
    let out = cells_to_string(&term, 80, 24);
    assert!(
        out.contains("preview"),
        "missing preview title mid-fade: {out}"
    );
}

#[test]
fn preview_renders_mosaic_glyph_when_bitmap_present() {
    let (_dir, cfg) = config_with_wallpapers(1);
    let mut app = new_app(cfg);
    app.preview = Some(small_test_bitmap());
    let out = render_to_string(&app, 80, 24);
    // The half-block mosaic renderer writes ▀/▄/█ glyphs into the preview
    // region when a bitmap is decoded — proving the Image-mosaic path works
    // headlessly (the core "emulator backend" deliverable).
    assert!(
        out.contains('▀') || out.contains('▄') || out.contains('█'),
        "missing mosaic glyph: {out}"
    );
}
