//! Wizard state machine. `handle_key` is a pure transition function over App —
//! all screen flow logic lives here so it is unit-testable without a terminal.

use crossterm::event::{KeyCode, KeyEvent};

use crate::config::{validate_hostname, validate_username, InstallConfig, Variant};
use crate::disks::Disk;
use crate::install;

const GIB: u64 = 1024 * 1024 * 1024;
/// Floor for the btrfs root: the desktop closure alone is ~12 GiB.
const MIN_ROOT_GIB: u64 = 20;

/// Minimum target disk size for the disko layout (ESP + swap + root).
fn required_disk_gib(swap_gib: u64) -> u64 {
    2 + swap_gib + MIN_ROOT_GIB
}

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
    /// Set when the user finishes the Confirm screen; `main()` spawns the runner.
    pub start_install: bool,
    /// Set on the Done screen when the user asks to reboot.
    pub reboot: bool,
}

impl App {
    #[must_use]
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
                        let need_gib = required_disk_gib(self.config.swap_size_gib);
                        if d.size_bytes < need_gib * GIB {
                            self.error = Some(format!(
                                "disk too small: need ≥ {need_gib} GiB (2G ESP + {}G swap + {MIN_ROOT_GIB}G root), {} has {}",
                                self.config.swap_size_gib,
                                d.path,
                                d.human_size()
                            ));
                        } else {
                            self.config.disk = d.path.clone();
                            self.error = None;
                            self.screen = Screen::VariantSelect;
                        }
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
