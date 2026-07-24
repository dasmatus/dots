//! Wizard state-machine tests (screen flow, validation, install events).

use crossterm::event::{KeyCode, KeyEvent};
use dots_installer::app::{App, Screen};
use dots_installer::install;
use dots_installer::net::{self, WifiNetwork};

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::from(code)
}

fn app() -> App {
    App::new("/dev/nvme0n1".into())
}

fn type_str(app: &mut App, s: &str) {
    for c in s.chars() {
        app.handle_key(key(KeyCode::Char(c)));
    }
}

/// An App parked on the Network screen with a canned two-network list: a
/// secured one at index 0 and an open one at index 1.
fn app_on_network_screen() -> App {
    let mut app = app();
    app.screen = Screen::Network;
    app.wifi_networks = vec![
        WifiNetwork {
            ssid: "secured-net".into(),
            signal: 80,
            security: "WPA2".into(),
        },
        WifiNetwork {
            ssid: "open-net".into(),
            signal: 60,
            security: String::new(),
        },
    ];
    app
}

#[test]
fn welcome_enter_opens_network_screen_and_requests_scan() {
    let mut app = app();
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Network);
    assert_eq!(app.pending_net_op, Some(net::Op::Scan));
    assert!(app.net_busy.is_some());
}

#[test]
fn welcome_esc_quits() {
    let mut app = app();
    app.handle_key(key(KeyCode::Esc));
    assert!(app.should_quit);
}

#[test]
fn network_skip_advances_to_hostname() {
    let mut app = app_on_network_screen();
    app.handle_key(key(KeyCode::Char('s')));
    assert_eq!(app.screen, Screen::Hostname);
}

#[test]
fn network_esc_returns_to_welcome() {
    let mut app = app_on_network_screen();
    app.handle_key(key(KeyCode::Esc));
    assert_eq!(app.screen, Screen::Welcome);
}

#[test]
fn scan_results_populate_list_and_clear_busy() {
    let mut app = app();
    app.screen = Screen::Network;
    app.net_busy = Some("scanning for networks…".into());
    app.on_net_event(net::Event::ScanDone(Ok(vec![
        WifiNetwork {
            ssid: "one".into(),
            signal: 50,
            security: "WPA2".into(),
        },
        WifiNetwork {
            ssid: "two".into(),
            signal: 30,
            security: String::new(),
        },
    ])));
    assert_eq!(app.wifi_networks.len(), 2);
    assert_eq!(app.wifi_selected, 0);
    assert!(app.net_busy.is_none());
}

#[test]
fn scan_failure_surfaces_error() {
    let mut app = app();
    app.screen = Screen::Network;
    app.net_busy = Some("scanning for networks…".into());
    app.on_net_event(net::Event::ScanDone(Err("nmcli not found".into())));
    assert!(app.net_busy.is_none());
    assert!(app.error.as_deref().unwrap().contains("nmcli not found"));
    assert_eq!(app.screen, Screen::Network);
}

#[test]
fn selecting_secured_network_prompts_for_passphrase() {
    let mut app = app_on_network_screen();
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiPassword);
    assert_eq!(app.wifi_ssid, "secured-net");
    assert_eq!(app.pending_net_op, None);
}

#[test]
fn selecting_open_network_connects_immediately() {
    let mut app = app_on_network_screen();
    app.wifi_selected = 1;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiConnecting);
    assert_eq!(
        app.pending_net_op,
        Some(net::Op::Connect {
            ssid: "open-net".into(),
            password: None,
        })
    );
}

#[test]
fn enter_during_scan_is_ignored() {
    let mut app = app_on_network_screen();
    app.net_busy = Some("scanning for networks…".into());
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Network);
    assert_eq!(app.pending_net_op, None);
}

#[test]
fn passphrase_length_enforced() {
    let mut app = app_on_network_screen();
    app.wifi_ssid = "secured-net".into();
    app.screen = Screen::WifiPassword;
    type_str(&mut app, "short");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiPassword);
    assert!(app.error.is_some());

    app.input.clear();
    app.error = None;
    type_str(&mut app, &"a".repeat(64));
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiPassword);
    assert!(app.error.is_some());
}

#[test]
fn passphrase_enter_starts_connection() {
    let mut app = app_on_network_screen();
    app.wifi_ssid = "secured-net".into();
    app.screen = Screen::WifiPassword;
    type_str(&mut app, "hunter222");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiConnecting);
    assert_eq!(
        app.pending_net_op,
        Some(net::Op::Connect {
            ssid: "secured-net".into(),
            password: Some("hunter222".into()),
        })
    );
    assert!(app.input.is_empty());
}

#[test]
fn wifi_password_esc_backs_out_to_network() {
    let mut app = app_on_network_screen();
    app.screen = Screen::WifiPassword;
    type_str(&mut app, "partial");
    app.handle_key(key(KeyCode::Esc));
    assert_eq!(app.screen, Screen::Network);
    assert!(app.input.is_empty());
}

#[test]
fn connect_success_advances_to_hostname() {
    let mut app = app();
    app.screen = Screen::WifiConnecting;
    app.on_net_event(net::Event::ConnectDone(Ok(())));
    assert_eq!(app.screen, Screen::Hostname);
    assert_eq!(app.online, Some(true));
}

#[test]
fn connect_failure_returns_to_network_with_error() {
    let mut app = app();
    app.screen = Screen::WifiConnecting;
    app.on_net_event(net::Event::ConnectDone(Err("bad passphrase".into())));
    assert_eq!(app.screen, Screen::Network);
    assert!(app.error.as_deref().unwrap().contains("bad passphrase"));
}

#[test]
fn late_scan_event_never_changes_screen() {
    let mut app = app();
    app.screen = Screen::Hostname;
    app.on_net_event(net::Event::ScanDone(Ok(vec![WifiNetwork {
        ssid: "late".into(),
        signal: 10,
        security: String::new(),
    }])));
    assert_eq!(app.screen, Screen::Hostname);
}

#[test]
fn wifi_connecting_ignores_keys() {
    let mut app = app();
    app.screen = Screen::WifiConnecting;
    app.handle_key(key(KeyCode::Esc));
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::WifiConnecting);
}

#[test]
fn connectivity_event_sets_online_flag() {
    let mut app = app();
    assert_eq!(app.online, None);
    app.on_net_event(net::Event::Connectivity(true));
    assert_eq!(app.online, Some(true));
    app.on_net_event(net::Event::Connectivity(false));
    assert_eq!(app.online, Some(false));
}

#[test]
fn app_stores_autodetected_disk() {
    assert_eq!(app().config.disk, "/dev/nvme0n1");
}

#[test]
fn hostname_empty_uses_default() {
    let mut app = app();
    app.screen = Screen::Hostname;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.config.hostname, "tokyonight");
    assert_eq!(app.screen, Screen::Username);
}

#[test]
fn hostname_rejects_invalid_and_stays() {
    let mut app = app();
    app.screen = Screen::Hostname;
    type_str(&mut app, "Bad_Host!");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Hostname);
    assert!(app.error.is_some());
}

#[test]
fn username_is_required() {
    let mut app = app();
    app.screen = Screen::Username;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Username);
    assert!(app.error.is_some());
}

#[test]
fn password_mismatch_restarts_entry_with_error() {
    let mut app = app();
    app.screen = Screen::RootPassword;
    type_str(&mut app, "hunter2");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::RootPasswordConfirm);
    type_str(&mut app, "different");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::RootPassword);
    assert!(app.error.is_some());
    assert!(app.config.root_password.is_empty());
}

#[test]
fn matching_passwords_advance() {
    let mut app = app();
    app.screen = Screen::RootPassword;
    type_str(&mut app, "hunter2");
    app.handle_key(key(KeyCode::Enter));
    type_str(&mut app, "hunter2");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.config.root_password, "hunter2");
    assert_eq!(app.screen, Screen::UserPassword);
}

#[test]
fn empty_password_rejected() {
    let mut app = app();
    app.screen = Screen::RootPassword;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::RootPassword);
    assert!(app.error.is_some());
}

#[test]
fn confirm_requires_exact_erase() {
    let mut app = app();
    app.screen = Screen::Confirm;
    type_str(&mut app, "erase");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Confirm, "lowercase must not pass");
    assert!(!app.start_install);

    app.input.clear();
    type_str(&mut app, "ERASE");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Installing);
    assert!(app.start_install);
}

#[test]
fn confirm_esc_backs_out_to_hostname() {
    let mut app = app();
    app.screen = Screen::Confirm;
    app.handle_key(key(KeyCode::Esc));
    assert_eq!(app.screen, Screen::Hostname);
}

#[test]
fn installing_ignores_keys() {
    let mut app = app();
    app.screen = Screen::Installing;
    app.handle_key(key(KeyCode::Esc));
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Installing);
    assert!(!app.should_quit);
}

#[test]
fn install_events_drive_progress_and_completion() {
    let mut app = app();
    app.screen = Screen::Installing;
    app.on_install_event(install::Event::StepStarted(2, 6, "disko".into()));
    assert_eq!(app.current_step, 2);
    assert_eq!(app.total_steps, 6);
    app.on_install_event(install::Event::Log("formatting".into()));
    assert_eq!(app.log.last().unwrap(), "formatting");
    app.on_install_event(install::Event::RecoveryKey("abc-def".into()));
    assert_eq!(app.recovery_key.as_deref(), Some("abc-def"));
    app.on_install_event(install::Event::Finished);
    assert_eq!(app.screen, Screen::Done);
}

#[test]
fn install_failure_shows_failed_screen() {
    let mut app = app();
    app.screen = Screen::Installing;
    app.on_install_event(install::Event::Failed("boom".into()));
    assert_eq!(app.screen, Screen::Failed);
    assert!(app.error.as_deref().unwrap().contains("boom"));
}

#[test]
fn done_enter_requests_reboot() {
    let mut app = app();
    app.screen = Screen::Done;
    app.handle_key(key(KeyCode::Enter));
    assert!(app.reboot);
    assert!(app.should_quit);
}
