//! Wizard state machine. `handle_key` is a pure transition function over App.
//! All screen flow logic lives here so it is unit-testable without a terminal.

use crate::input::{KeyCode, KeyEvent};

use crate::config::{
    validate_git_email, validate_git_name, validate_hostname, validate_username, InstallConfig,
};
use crate::disks::{self, Disk};
use crate::install;
use crate::net;

/// Number of toggles on the `Ai` screen (Claude, Codex, Ollama). Keeps the
/// `Down` cursor clamp and the `Space` toggle dispatch in sync with the view.
pub const AI_OPTIONS: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Welcome,
    Network,
    WifiPassword,
    WifiConnecting,
    /// Manual target-disk picker, shown only when `autodetect_disk` couldn't
    /// pick a single disk unambiguously (multiple fixed disks, or none large
    /// enough). When autodetection succeeded this screen is skipped.
    DiskSelect,
    Hostname,
    Username,
    GitName,
    GitEmail,
    /// AI tooling toggles (Claude Code / Codex CLI / Ollama) → settings.ai*,
    /// bridged to options.dots.ai.* by nix/modules/dots.nix. Defaults to all
    /// on; Space flips a toggle, Enter advances to UserPassword.
    Ai,
    UserPassword,
    UserPasswordConfirm,
    Confirm,
    Installing,
    Done,
    Failed,
}

#[derive(Debug, Clone)]
pub struct App {
    pub screen: Screen,
    pub config: InstallConfig,
    /// Disks offered by the manual picker; empty when autodetection succeeded.
    pub disks: Vec<Disk>,
    pub selected: usize,
    /// Per-`disks` selection mask for the multi-select picker.
    pub picked: Vec<bool>,
    /// Cursor on the `Ai` toggle list (0 = Claude, 1 = Codex, 2 = Ollama).
    pub ai_selected: usize,
    /// True when `autodetect_disk` pre-picked the disk → skip `DiskSelect`.
    pub disk_auto: bool,
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
    pub wifi_networks: Vec<net::WifiNetwork>,
    pub wifi_selected: usize,
    /// SSID awaiting a passphrase / being connected to.
    pub wifi_ssid: String,
    /// None until the first connectivity check answers.
    pub online: Option<bool>,
    /// Worker status shown on the Network screen ("scanning…" / "connecting…").
    pub net_busy: Option<String>,
    /// Set by `handle_key`; `main()` takes it and spawns the worker (keeps the state machine pure).
    pub pending_net_op: Option<net::Op>,
}

impl App {
    /// Build the wizard. `auto` is the path `autodetect_disk` picked, when it
    /// could pick one unambiguously. In that case `DiskSelect` is skipped.
    /// When `auto` is `None`, `disks` is offered via the multi-select picker.
    #[must_use]
    pub fn new(disks: Vec<Disk>, auto: Option<String>) -> Self {
        let (config_disks, disk_auto) = match auto {
            Some(d) => (vec![d], true),
            None => (Vec::new(), false),
        };
        Self {
            screen: Screen::Welcome,
            config: InstallConfig {
                disks: config_disks,
                // AI tooling defaults to on; the AI screen lets the user turn
                // any off. `Default` would leave these `false`, so set them here.
                ai_claude: true,
                ai_codex: true,
                ai_ollama: true,
                ..InstallConfig::default()
            },
            picked: vec![false; disks.len()],
            disks,
            selected: 0,
            ai_selected: 0,
            disk_auto,
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
            wifi_networks: Vec::new(),
            wifi_selected: 0,
            wifi_ssid: String::new(),
            online: None,
            net_busy: None,
            pending_net_op: None,
        }
    }

    /// Where the Network screen hands off to: the manual picker when
    /// autodetection didn't pre-pick the disk, else straight to Hostname.
    fn after_network(&self) -> Screen {
        if self.disk_auto {
            Screen::Hostname
        } else {
            Screen::DiskSelect
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        match self.screen {
            Screen::Welcome => match key.code {
                KeyCode::Enter => {
                    self.screen = Screen::Network;
                    self.pending_net_op = Some(net::Op::Scan);
                    self.net_busy = Some("scanning for networks…".into());
                }
                KeyCode::Esc | KeyCode::Char('q') => self.should_quit = true,
                _ => {}
            },

            Screen::Network => match key.code {
                KeyCode::Up => self.wifi_selected = self.wifi_selected.saturating_sub(1),
                KeyCode::Down => {
                    if self.wifi_selected + 1 < self.wifi_networks.len() {
                        self.wifi_selected += 1;
                    }
                }
                KeyCode::Char('r') if self.net_busy.is_none() => {
                    self.error = None;
                    self.net_busy = Some("scanning for networks…".into());
                    self.pending_net_op = Some(net::Op::Scan);
                }
                KeyCode::Char('s') => {
                    self.screen = self.after_network();
                    self.error = None;
                }
                KeyCode::Enter if self.net_busy.is_none() => {
                    if let Some(n) = self.wifi_networks.get(self.wifi_selected) {
                        self.wifi_ssid = n.ssid.clone();
                        self.error = None;
                        if n.is_open() {
                            self.pending_net_op = Some(net::Op::Connect {
                                ssid: self.wifi_ssid.clone(),
                                password: None,
                            });
                            self.net_busy = Some(format!("connecting to {}…", self.wifi_ssid));
                            self.screen = Screen::WifiConnecting;
                        } else {
                            self.input.clear();
                            self.screen = Screen::WifiPassword;
                        }
                    } else {
                        self.error = Some("no networks found — r to rescan, s to skip".into());
                    }
                }
                KeyCode::Esc => self.screen = Screen::Welcome,
                _ => {}
            },

            Screen::WifiPassword => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    if (8..=63).contains(&self.input.len()) {
                        let password = std::mem::take(&mut self.input);
                        self.pending_net_op = Some(net::Op::Connect {
                            ssid: self.wifi_ssid.clone(),
                            password: Some(password),
                        });
                        self.net_busy = Some(format!("connecting to {}…", self.wifi_ssid));
                        self.error = None;
                        self.screen = Screen::WifiConnecting;
                    } else {
                        self.error = Some("passphrase must be 8–63 characters".into());
                    }
                }
                KeyCode::Esc => {
                    self.input.clear();
                    self.error = None;
                    self.screen = Screen::Network;
                }
                _ => {}
            },

            Screen::DiskSelect => match key.code {
                KeyCode::Up => self.selected = self.selected.saturating_sub(1),
                KeyCode::Down => {
                    if self.selected + 1 < self.disks.len() {
                        self.selected += 1;
                    }
                }
                // Space toggles membership in the multi-select set; Enter
                // confirms. The chosen disks span one LVM volume group, so
                // the capacity gate is on their combined size, not any one.
                KeyCode::Char(' ') => {
                    if let Some(p) = self.picked.get_mut(self.selected) {
                        *p = !*p;
                        self.error = None;
                    }
                }
                KeyCode::Enter => {
                    let chosen: Vec<&Disk> = self
                        .disks
                        .iter()
                        .zip(self.picked.iter())
                        .filter_map(|(d, p)| p.then_some(d))
                        .collect();
                    if chosen.is_empty() {
                        self.error = Some("select at least one disk (Space to toggle)".into());
                    } else {
                        let need_gib = disks::required_gib(self.config.swap_size_gib);
                        let total: u64 = chosen.iter().map(|d| d.size_bytes).sum();
                        if total < need_gib * disks::GIB {
                            let paths = chosen
                                .iter()
                                .map(|d| d.path.as_str())
                                .collect::<Vec<_>>()
                                .join(", ");
                            self.error = Some(format!(
                                "span too small: need ≥ {need_gib} GiB across the VG ({}G ESP + {}G swap + {}G root), {paths} total {} GiB",
                                disks::ESP_GIB,
                                self.config.swap_size_gib,
                                disks::ROOT_GIB,
                                total / disks::GIB
                            ));
                        } else {
                            self.config.disks = chosen.iter().map(|d| d.path.clone()).collect();
                            self.error = None;
                            self.screen = Screen::Hostname;
                        }
                    }
                }
                KeyCode::Esc => self.screen = Screen::Network,
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
                        self.screen = Screen::GitName;
                    }
                    Err(e) => self.error = Some(e),
                },
                _ => {}
            },

            Screen::GitName => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => match validate_git_name(&self.input) {
                    Ok(()) => {
                        self.config.git_name = self.input.clone();
                        self.input.clear();
                        self.error = None;
                        self.screen = Screen::GitEmail;
                    }
                    Err(e) => self.error = Some(e),
                },
                KeyCode::Esc => {
                    self.input.clear();
                    self.error = None;
                    self.screen = Screen::Username;
                }
                _ => {}
            },

            Screen::GitEmail => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => match validate_git_email(&self.input) {
                    Ok(()) => {
                        self.config.git_email = self.input.clone();
                        self.input.clear();
                        self.error = None;
                        self.screen = Screen::Ai;
                    }
                    Err(e) => self.error = Some(e),
                },
                KeyCode::Esc => {
                    self.input.clear();
                    self.error = None;
                    self.screen = Screen::GitName;
                }
                _ => {}
            },

            Screen::Ai => match key.code {
                KeyCode::Up => self.ai_selected = self.ai_selected.saturating_sub(1),
                KeyCode::Down => {
                    if self.ai_selected + 1 < AI_OPTIONS {
                        self.ai_selected += 1;
                    }
                }
                // Space flips the focused toggle; the three toggles map 1:1 to
                // settings.aiClaude / aiCodex / aiOllama (nix/modules/dots.nix).
                KeyCode::Char(' ') => {
                    match self.ai_selected {
                        0 => self.config.ai_claude = !self.config.ai_claude,
                        1 => self.config.ai_codex = !self.config.ai_codex,
                        _ => self.config.ai_ollama = !self.config.ai_ollama,
                    }
                    self.error = None;
                }
                KeyCode::Enter => self.screen = Screen::UserPassword,
                KeyCode::Esc => self.screen = Screen::GitEmail,
                _ => {}
            },

            Screen::UserPassword => match key.code {
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
                        self.screen = Screen::UserPasswordConfirm;
                    }
                }
                _ => {}
            },

            Screen::UserPasswordConfirm => match key.code {
                KeyCode::Char(c) => self.input.push(c),
                KeyCode::Backspace => {
                    self.input.pop();
                }
                KeyCode::Enter => {
                    let confirmed = std::mem::take(&mut self.input);
                    if confirmed == self.pending_password {
                        self.config.user_password = std::mem::take(&mut self.pending_password);
                        self.screen = Screen::Confirm;
                        self.error = None;
                    } else {
                        self.pending_password.clear();
                        self.error = Some("passwords do not match, try again".into());
                        self.screen = Screen::UserPassword;
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
                    self.screen = self.after_network();
                }
                _ => {}
            },

            // No user-cancel mid-install/mid-connect: a half-written disk is
            // worse, and interrupting nmcli mid-handshake helps nobody.
            Screen::Installing | Screen::WifiConnecting => {}

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

    /// `ScanDone`/`Connectivity` never change the screen — they may arrive
    /// after the user has skipped ahead; only `ConnectDone` transitions, and
    /// only from `WifiConnecting`.
    pub fn on_net_event(&mut self, ev: net::Event) {
        match ev {
            net::Event::Connectivity(online) => self.online = Some(online),
            net::Event::ScanDone(Ok(nets)) => {
                self.wifi_networks = nets;
                self.wifi_selected = 0;
                self.net_busy = None;
            }
            net::Event::ScanDone(Err(e)) => {
                self.net_busy = None;
                self.error = Some(format!("Wi-Fi scan failed: {e}"));
            }
            net::Event::ConnectDone(Ok(())) => {
                self.net_busy = None;
                self.online = Some(true);
                self.error = None;
                if self.screen == Screen::WifiConnecting {
                    self.screen = self.after_network();
                }
            }
            net::Event::ConnectDone(Err(e)) => {
                self.net_busy = None;
                self.error = Some(format!("connection failed: {e}"));
                if self.screen == Screen::WifiConnecting {
                    self.screen = Screen::Network;
                }
            }
        }
    }
}
