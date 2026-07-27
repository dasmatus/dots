//! Headless render tests for the installer TUI view. Each test mounts
//! `ui::root_view` over a `Signal<App>` set to a canned state, pumps one frame
//! into a `CaptureTerm`, and asserts the rendered cells contain the expected
//! user-visible strings (titles, prompts, hints, echoed input).

use abstracttui::anim::Clock;
use abstracttui::app::{App as Engine, Driver, RunConfig};
use abstracttui::prelude::*;
use abstracttui::testing::CaptureTerm;

use dots_installer::app::{App, Screen};
use dots_installer::fx::ScreenFx;
use dots_installer::ui;

/// Render `app` at `cols`×`rows` and return the concatenated cell text, one
/// row per line. Uses the engine's `Driver` + `CaptureTerm` headless path
/// confirmed in `docs/superpowers/refs/abstracttui-api.md`.
fn render_to_string(app: &App, cols: i32, rows: i32) -> String {
    let mut engine = Engine::new(Size::new(cols, rows));
    engine
        .mount(|cx| {
            let app_sig = cx.signal(app.clone());
            let fx_sig = cx.signal(ScreenFx::new(Clock::real()));
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

#[test]
fn welcome_screen_renders_title_and_hint() {
    let app = App::new(vec![], Some("/dev/nvme0n1".into()));
    let out = render_to_string(&app, 80, 24);
    assert!(
        out.contains("tokyonight-dots installer"),
        "missing title: {out}"
    );
    assert!(out.contains("Enter continue"), "missing hint: {out}");
}

#[test]
fn hostname_screen_shows_prompt_and_input_cursor() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Hostname;
    app.input = "desk".into();
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("Hostname"), "missing prompt: {out}");
    assert!(out.contains("desk"), "missing echoed input: {out}");
}

#[test]
fn confirm_screen_shows_erase_prompt_and_typed_text() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Confirm;
    app.input = "ERA".into();
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("ERASE"), "missing ERASE prompt: {out}");
    assert!(out.contains("ERA"), "missing typed text: {out}");
}
