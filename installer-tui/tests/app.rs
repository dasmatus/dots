//! Wizard state-machine tests (screen flow, validation, install events).

use crossterm::event::{KeyCode, KeyEvent};
use dots_installer::app::{App, Screen};
use dots_installer::disks::Disk;
use dots_installer::install;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::from(code)
}

fn app_with_disks() -> App {
    App::new(vec![
        Disk {
            path: "/dev/nvme0n1".into(),
            size_bytes: 512_110_190_592,
            model: "SSD".into(),
            removable: false,
        },
        Disk {
            path: "/dev/sda".into(),
            size_bytes: 240_057_409_536,
            model: "SATA SSD".into(),
            removable: false,
        },
        Disk {
            path: "/dev/sdb".into(),
            size_bytes: 15_931_539_456,
            model: "USB".into(),
            removable: true,
        },
    ])
}

fn type_str(app: &mut App, s: &str) {
    for c in s.chars() {
        app.handle_key(key(KeyCode::Char(c)));
    }
}

#[test]
fn welcome_enter_advances_to_disk_select() {
    let mut app = app_with_disks();
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::DiskSelect);
}

#[test]
fn welcome_esc_quits() {
    let mut app = app_with_disks();
    app.handle_key(key(KeyCode::Esc));
    assert!(app.should_quit);
}

#[test]
fn disk_select_stores_chosen_path() {
    let mut app = app_with_disks();
    app.screen = Screen::DiskSelect;
    app.handle_key(key(KeyCode::Down));
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.config.disk, "/dev/sda");
    assert_eq!(app.screen, Screen::Hostname);
}

#[test]
fn disk_select_rejects_too_small_disk_before_anything_is_wiped() {
    let mut app = app_with_disks();
    app.config.swap_size_gib = 16;
    app.screen = Screen::DiskSelect;
    app.selected = 2;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(
        app.screen,
        Screen::DiskSelect,
        "15GB stick can't fit 2+16+20 GiB"
    );
    assert!(app.error.as_deref().unwrap().contains("too small"));
    assert!(app.config.disk.is_empty());
}

#[test]
fn hostname_empty_uses_default() {
    let mut app = app_with_disks();
    app.screen = Screen::Hostname;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.config.hostname, "tokyonight");
    assert_eq!(app.screen, Screen::Username);
}

#[test]
fn hostname_rejects_invalid_and_stays() {
    let mut app = app_with_disks();
    app.screen = Screen::Hostname;
    type_str(&mut app, "Bad_Host!");
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Hostname);
    assert!(app.error.is_some());
}

#[test]
fn username_is_required() {
    let mut app = app_with_disks();
    app.screen = Screen::Username;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Username);
    assert!(app.error.is_some());
}

#[test]
fn password_mismatch_restarts_entry_with_error() {
    let mut app = app_with_disks();
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
    let mut app = app_with_disks();
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
    let mut app = app_with_disks();
    app.screen = Screen::RootPassword;
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::RootPassword);
    assert!(app.error.is_some());
}

#[test]
fn confirm_requires_exact_erase() {
    let mut app = app_with_disks();
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
fn confirm_esc_backs_out_to_disk_select() {
    let mut app = app_with_disks();
    app.screen = Screen::Confirm;
    app.handle_key(key(KeyCode::Esc));
    assert_eq!(app.screen, Screen::DiskSelect);
}

#[test]
fn installing_ignores_keys() {
    let mut app = app_with_disks();
    app.screen = Screen::Installing;
    app.handle_key(key(KeyCode::Esc));
    app.handle_key(key(KeyCode::Enter));
    assert_eq!(app.screen, Screen::Installing);
    assert!(!app.should_quit);
}

#[test]
fn install_events_drive_progress_and_completion() {
    let mut app = app_with_disks();
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
    let mut app = app_with_disks();
    app.screen = Screen::Installing;
    app.on_install_event(install::Event::Failed("boom".into()));
    assert_eq!(app.screen, Screen::Failed);
    assert!(app.error.as_deref().unwrap().contains("boom"));
}

#[test]
fn done_enter_requests_reboot() {
    let mut app = app_with_disks();
    app.screen = Screen::Done;
    app.handle_key(key(KeyCode::Enter));
    assert!(app.reboot);
    assert!(app.should_quit);
}
