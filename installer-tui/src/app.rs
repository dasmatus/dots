//! Wizard state machine. `handle_key` is a pure transition function over App —
//! all screen flow logic lives here so it is unit-testable without a terminal.

use crossterm::event::{KeyCode, KeyEvent};

use crate::config::{validate_hostname, validate_username, InstallConfig, Variant};
use crate::disks::Disk;
use crate::install;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Welcome,
    DiskSelect,
    VariantSelect,
    Hostname,
    Username,
    RootPassword,
    RootPasswordConfirm,
    UserPassword,
    UserPasswordConfirm,
    Confirm,
    Installing,
    Done,
    Failed,
}

#[derive(Debug)]
pub struct App {
    pub screen: Screen,
    pub config: InstallConfig,
    pub disks: Vec<Disk>,
    pub selected: usize,
    pub input: String,
    pub pending_password: String,
    pub error: Option<String>,
    pub log: Vec<String>,
    pub current_step: usize,
    pub total_steps: usize,
    pub step_title: String,
    pub recovery_key: Option<String>,
    pub should_quit: bool,
    /// Set when the user finishes the Confirm screen; main() spawns the runner.
    pub start_install: bool,
    /// Set on the Done screen when the user asks to reboot.
    pub reboot: bool,
}

impl App {
    pub fn new(disks: Vec<Disk>) -> Self {
        Self {
            screen: Screen::Welcome,
            config: InstallConfig::default(),
            disks,
            selected: 0,
            input: String::new(),
            pending_password: String::new(),
            error: None,
            log: Vec::new(),
            current_step: 0,
            total_steps: 0,
            step_title: String::new(),
            recovery_key: None,
            should_quit: false,
            start_install: false,
            reboot: false,
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        match self.screen {
            Screen::Welcome => match key.code {
                KeyCode::Enter => self.screen = Screen::DiskSelect,
                KeyCode::Esc | KeyCode::Char('q') => self.should_quit = true,
                _ => {}
            },

            Screen::DiskSelect => match key.code {
                KeyCode::Up => self.selected = self.selected.saturating_sub(1),
                KeyCode::Down => {
                    if self.selected + 1 < self.disks.len() {
                        self.selected += 1;
                    }
                }
                KeyCode::Enter => {
                    if let Some(d) = self.disks.get(self.selected) {
                        self.config.disk = d.path.clone();
                        self.error = None;
                        self.screen = Screen::VariantSelect;
                    } else {
                        self.error = Some("no installable disks found".into());
                    }
                }
                KeyCode::Esc => self.screen = Screen::Welcome,
                _ => {}
            },

            Screen::VariantSelect => match key.code {
                KeyCode::Up => self.config.variant = Variant::Intel,
                KeyCode::Down => self.config.variant = Variant::Amd,
                KeyCode::Enter => {
                    self.error = None;
                    self.screen = Screen::Hostname;
                }
                KeyCode::Esc => self.screen = Screen::DiskSelect,
                _ => {}
            },

            Screen::Hostname => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    let candidate = if self.input.is_empty() {
                        "tokyonight".to_string()
                    } else {
                        self.input.clone()
                    };
                    match validate_hostname(&candidate) {
                        Ok(()) => {
                            self.config.hostname = candidate;
                            self.input.clear();
                            self.error = None;
                            self.screen = Screen::Username;
                        }
                        Err(e) => self.error = Some(e),
                    }
                }
                _ => {}
            },

            Screen::Username => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => match validate_username(&self.input) {
                    Ok(()) => {
                        self.config.username = self.input.clone();
                        self.input.clear();
                        self.error = None;
                        self.screen = Screen::RootPassword;
                    }
                    Err(e) => self.error = Some(e),
                },
                _ => {}
            },

            Screen::RootPassword | Screen::UserPassword => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    if self.input.is_empty() {
                        self.error = Some("password must not be empty".into());
                    } else {
                        self.pending_password = std::mem::take(&mut self.input);
                        self.error = None;
                        self.screen = if self.screen == Screen::RootPassword {
                            Screen::RootPasswordConfirm
                        } else {
                            Screen::UserPasswordConfirm
                        };
                    }
                }
                _ => {}
            },

            Screen::RootPasswordConfirm | Screen::UserPasswordConfirm => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    let confirmed = std::mem::take(&mut self.input);
                    let is_root = self.screen == Screen::RootPasswordConfirm;
                    if confirmed == self.pending_password {
                        if is_root {
                            self.config.root_password = std::mem::take(&mut self.pending_password);
                            self.screen = Screen::UserPassword;
                        } else {
                            self.config.user_password = std::mem::take(&mut self.pending_password);
                            self.screen = Screen::Confirm;
                        }
                        self.error = None;
                    } else {
                        self.pending_password.clear();
                        self.error = Some("passwords do not match, try again".into());
                        self.screen = if is_root {
                            Screen::RootPassword
                        } else {
                            Screen::UserPassword
                        };
                    }
                }
                _ => {}
            },

            Screen::Confirm => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    if self.input == "ERASE" {
                        self.input.clear();
                        self.error = None;
                        self.start_install = true;
                        self.screen = Screen::Installing;
                    } else {
                        self.error = Some("type ERASE (uppercase) to proceed".into());
                    }
                }
                KeyCode::Esc => {
                    self.input.clear();
                    self.error = None;
                    self.screen = Screen::DiskSelect;
                }
                _ => {}
            },

            // No user-cancel mid-install: a half-written disk is worse.
            Screen::Installing => {}

            Screen::Done => {
                if key.code == KeyCode::Enter {
                    self.reboot = true;
                    self.should_quit = true;
                }
            }

            Screen::Failed => match key.code {
                KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q') => self.should_quit = true,
                _ => {}
            },
        }
    }

    pub fn on_install_event(&mut self, ev: install::Event) {
        match ev {
            install::Event::StepStarted(i, total, title) => {
                self.current_step = i;
                self.total_steps = total;
                self.log.push(format!("==> {title}"));
                self.step_title = title;
            }
            install::Event::Log(line) => {
                self.log.push(line);
                if self.log.len() > 1000 {
                    self.log.drain(..self.log.len() - 1000);
                }
            }
            install::Event::RecoveryKey(k) => self.recovery_key = Some(k),
            install::Event::Finished => self.screen = Screen::Done,
            install::Event::Failed(e) => {
                self.error = Some(format!("Installation failed: {e}"));
                self.screen = Screen::Failed;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyCode;

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
        assert_eq!(app.screen, Screen::VariantSelect);
    }

    #[test]
    fn variant_toggle_and_select() {
        let mut app = app_with_disks();
        app.screen = Screen::VariantSelect;
        app.handle_key(key(KeyCode::Down));
        app.handle_key(key(KeyCode::Enter));
        assert_eq!(app.config.variant, Variant::Amd);
        assert_eq!(app.screen, Screen::Hostname);
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
}
