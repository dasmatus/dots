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

use dots_installer::disks::Disk;
use dots_installer::net::WifiNetwork;

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

#[test]
fn network_screen_lists_wifi_networks_with_selection_marker() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Network;
    app.wifi_networks = vec![
        WifiNetwork {
            ssid: "home".into(),
            signal: 80,
            security: "WPA2".into(),
        },
        WifiNetwork {
            ssid: "cafe".into(),
            signal: 40,
            security: String::new(),
        },
    ];
    app.wifi_selected = 0;
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("home"), "missing ssid: {out}");
    assert!(out.contains("cafe"), "missing ssid: {out}");
    assert!(out.contains("WPA2"), "missing security: {out}");
    assert!(out.contains("open"), "missing open marker: {out}");
}

#[test]
fn disk_select_shows_picked_disks_with_ascii_marker() {
    let mut app = App::new(
        vec![Disk {
            path: "/dev/vda".into(),
            size_bytes: 64 * 1024 * 1024 * 1024,
            model: "VMware".into(),
            removable: false,
        }],
        None,
    );
    app.screen = Screen::DiskSelect;
    app.picked = vec![true];
    app.selected = 0;
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("/dev/vda"), "missing disk path: {out}");
    assert!(out.contains("[x]"), "missing picked marker: {out}");
}

#[test]
fn wifi_connecting_shows_ssid_and_wait_hint() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::WifiConnecting;
    app.wifi_ssid = "home".into();
    let out = render_to_string(&app, 80, 24);
    assert!(
        out.contains("connecting to \"home\""),
        "missing connecting line: {out}"
    );
    assert!(out.contains("please wait"), "missing hint: {out}");
}

#[test]
fn installing_screen_shows_step_count_and_log_tail() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Installing;
    app.current_step = 2;
    app.total_steps = 5;
    app.step_title = "formatting".into();
    app.log.push("==> formatting".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("step 2/5"), "missing step count: {out}");
    assert!(out.contains("formatting"), "missing step title: {out}");
    assert!(out.contains("==> formatting"), "missing log tail: {out}");
}

#[test]
fn done_screen_shows_recovery_key() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Done;
    app.recovery_key = Some("RECOVERY-1234".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("RECOVERY-1234"), "missing recovery key: {out}");
    assert!(out.contains("Enter reboot"), "missing reboot hint: {out}");
}

#[test]
fn failed_screen_shows_error_message() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Failed;
    app.error = Some("disk blew up".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("disk blew up"), "missing error: {out}");
}
