//! Rendering. Pure function of &App — no state lives here.

use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Gauge, Paragraph, Wrap};
use ratatui::Frame;

use crate::app::{App, Screen};

// Tokyonight (night) palette.
pub mod palette {
    use ratatui::style::Color;

    pub const BG: Color = Color::Rgb(0x1a, 0x1b, 0x26);
    pub const FG: Color = Color::Rgb(0xc0, 0xca, 0xf5);
    pub const BLUE: Color = Color::Rgb(0x7a, 0xa2, 0xf7);
    pub const CYAN: Color = Color::Rgb(0x7d, 0xcf, 0xff);
    pub const GREEN: Color = Color::Rgb(0x9e, 0xce, 0x6a);
    pub const MAGENTA: Color = Color::Rgb(0xbb, 0x9a, 0xf7);
    pub const RED: Color = Color::Rgb(0xf7, 0x76, 0x8e);
    pub const YELLOW: Color = Color::Rgb(0xe0, 0xaf, 0x68);
    pub const DIM: Color = Color::Rgb(0x56, 0x5f, 0x89);
}

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(palette::BG).fg(palette::FG)),
        area,
    );

    match app.screen {
        Screen::Installing => draw_installing(frame, app, area),
        Screen::Failed => draw_failed(frame, app, area),
        _ => draw_wizard(frame, app, area),
    }
}

fn draw_wizard(frame: &mut Frame, app: &App, area: Rect) {
    let boxed = centered(area, 72, 20);
    frame.render_widget(Clear, boxed);

    let (title, mut lines, hint) = match app.screen {
        Screen::Welcome => (
            " tokyonight-dots installer ",
            vec![
                Line::default(),
                Line::styled(
                    "  NixOS · TPM2-encrypted btrfs · i3 + Hyprland · Tokyonight",
                    Style::default().fg(palette::MAGENTA),
                ),
                Line::default(),
                Line::raw("  This wizard ERASES a disk and installs the tokyonight-dots"),
                Line::raw("  NixOS system from the flake bundled with this ISO."),
            ],
            "Enter continue · Esc quit",
        ),

        Screen::Network => {
            let mut lines = vec![
                Line::default(),
                Line::raw("  Wi-Fi setup — nixos-install pulls from the binary cache,"),
                Line::raw("  so get online unless this is the offline (iso-full) image."),
                Line::default(),
            ];
            lines.push(match app.online {
                None => Line::styled("  status: checking…", Style::default().fg(palette::DIM)),
                Some(true) => {
                    Line::styled("  status: online ✓", Style::default().fg(palette::GREEN))
                }
                Some(false) => {
                    Line::styled("  status: offline ✗", Style::default().fg(palette::YELLOW))
                }
            });
            if let Some(b) = &app.net_busy {
                lines.push(Line::styled(
                    format!("  {b}"),
                    Style::default().fg(palette::CYAN),
                ));
            }
            lines.push(Line::default());
            if app.wifi_networks.is_empty() && app.net_busy.is_none() {
                lines.push(Line::styled(
                    "  no Wi-Fi networks found (wired is fine too — press s)",
                    Style::default().fg(palette::DIM),
                ));
            }
            for (i, n) in app.wifi_networks.iter().enumerate() {
                let marker = if i == app.wifi_selected {
                    "  ▶ "
                } else {
                    "    "
                };
                let style = if i == app.wifi_selected {
                    Style::default()
                        .fg(palette::CYAN)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                let security = if n.is_open() {
                    "open"
                } else {
                    n.security.as_str()
                };
                lines.push(Line::styled(
                    format!("{marker}{} {}  {security}", n.signal_bars(), n.ssid),
                    style,
                ));
            }
            (
                " network ",
                lines,
                "↑/↓ select · Enter connect · r rescan · s skip · Esc back",
            )
        }

        Screen::WifiPassword => (
            " Wi-Fi passphrase ",
            input_lines(
                &format!("Passphrase for \"{}\":", app.wifi_ssid),
                &app.input,
                true,
            ),
            "Enter connect · Esc back",
        ),

        Screen::WifiConnecting => (
            " connecting ",
            vec![
                Line::default(),
                Line::styled(
                    format!("  connecting to \"{}\"…", app.wifi_ssid),
                    Style::default().fg(palette::CYAN),
                ),
                Line::default(),
                Line::styled(
                    "  asking NetworkManager, this can take a few seconds",
                    Style::default().fg(palette::DIM),
                ),
            ],
            "please wait",
        ),

        Screen::DiskSelect => {
            let mut lines = vec![
                Line::default(),
                Line::raw("  Select the target disk (it will be ERASED):"),
                Line::default(),
            ];
            if app.disks.is_empty() {
                lines.push(Line::styled(
                    "  no installable disks found",
                    Style::default().fg(palette::RED),
                ));
            }
            for (i, d) in app.disks.iter().enumerate() {
                let marker = if i == app.selected { "  ▶ " } else { "    " };
                let removable = if d.removable { " [removable]" } else { "" };
                let style = if i == app.selected {
                    Style::default()
                        .fg(palette::CYAN)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                lines.push(Line::styled(
                    format!(
                        "{marker}{}  {}  {}{removable}",
                        d.path,
                        d.human_size(),
                        d.model
                    ),
                    style,
                ));
            }
            (
                " target disk ",
                lines,
                "↑/↓ select · Enter confirm · Esc back",
            )
        }

        Screen::Hostname => (
            " hostname ",
            input_lines("Hostname (empty = \"tokyonight\"):", &app.input, false),
            "Enter confirm",
        ),
        Screen::Username => (
            " user ",
            input_lines("Username for the primary user:", &app.input, false),
            "Enter confirm",
        ),
        Screen::RootPassword => (
            " root password ",
            input_lines(
                "Root password (also the LUKS fallback passphrase):",
                &app.input,
                true,
            ),
            "Enter confirm",
        ),
        Screen::RootPasswordConfirm => (
            " root password ",
            input_lines("Repeat root password:", &app.input, true),
            "Enter confirm",
        ),
        Screen::UserPassword => (
            " user password ",
            input_lines("User password:", &app.input, true),
            "Enter confirm",
        ),
        Screen::UserPasswordConfirm => (
            " user password ",
            input_lines("Repeat user password:", &app.input, true),
            "Enter confirm",
        ),

        Screen::Confirm => (
            " point of no return ",
            vec![
                Line::default(),
                Line::styled(
                    format!(
                        "  ALL DATA on {} will be permanently erased!",
                        app.config.disk
                    ),
                    Style::default()
                        .fg(palette::RED)
                        .add_modifier(Modifier::BOLD),
                ),
                Line::default(),
                Line::raw(format!("    disk      {}", app.config.disk)),
                Line::raw(format!("    hostname  {}", app.config.hostname)),
                Line::raw(format!("    user      {}", app.config.username)),
                Line::raw(format!("    swap      {}G", app.config.swap_size_gib)),
                Line::default(),
                Line::raw("  Type ERASE to proceed:"),
                Line::styled(
                    format!("  > {}", app.input),
                    Style::default().fg(palette::YELLOW),
                ),
            ],
            "Enter proceed · Esc back",
        ),

        Screen::Done => {
            let key = app.recovery_key.as_deref().unwrap_or("(missing)");
            (
                " installed ",
                vec![
                    Line::default(),
                    Line::styled(
                        "  Installation finished.",
                        Style::default()
                            .fg(palette::GREEN)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Line::default(),
                    Line::raw("  LUKS recovery key (also in /root/luks-recovery.txt"),
                    Line::raw("  on the installed system) — WRITE IT DOWN:"),
                    Line::default(),
                    Line::styled(
                        format!("    {key}"),
                        Style::default()
                            .fg(palette::YELLOW)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Line::default(),
                    Line::raw("  Remove the installation medium, then press Enter to reboot."),
                ],
                "Enter reboot",
            )
        }

        Screen::Installing | Screen::Failed => unreachable!("handled by caller"),
    };

    if let Some(err) = &app.error {
        lines.push(Line::default());
        lines.push(Line::styled(
            format!("  ✗ {err}"),
            Style::default().fg(palette::RED),
        ));
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(palette::BLUE))
        .title(Span::styled(
            title,
            Style::default()
                .fg(palette::MAGENTA)
                .add_modifier(Modifier::BOLD),
        ))
        .title_bottom(
            Line::styled(format!(" {hint} "), Style::default().fg(palette::DIM))
                .alignment(Alignment::Right),
        );
    frame.render_widget(
        Paragraph::new(lines)
            .block(block)
            .wrap(Wrap { trim: false }),
        boxed,
    );
}

fn draw_installing(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3)])
        .split(area);

    let ratio = if app.total_steps == 0 {
        0.0
    } else {
        app.current_step as f64 / app.total_steps as f64
    };
    frame.render_widget(
        Gauge::default()
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(palette::BLUE))
                    .title(" installing "),
            )
            .gauge_style(Style::default().fg(palette::BLUE).bg(palette::BG))
            .label(format!(
                "step {}/{} — {}",
                app.current_step, app.total_steps, app.step_title
            ))
            .ratio(ratio),
        chunks[0],
    );

    let visible = chunks[1].height.saturating_sub(2) as usize;
    let tail: Vec<Line> = app
        .log
        .iter()
        .rev()
        .take(visible)
        .rev()
        .map(|l| Line::styled(l.clone(), Style::default().fg(palette::DIM)))
        .collect();
    frame.render_widget(
        Paragraph::new(tail).block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(palette::DIM))
                .title(" log "),
        ),
        chunks[1],
    );
}

fn draw_failed(frame: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(4), Constraint::Min(3)])
        .split(area);

    let msg = app.error.as_deref().unwrap_or("unknown error");
    frame.render_widget(
        Paragraph::new(vec![
            Line::styled(
                msg.to_string(),
                Style::default()
                    .fg(palette::RED)
                    .add_modifier(Modifier::BOLD),
            ),
            Line::styled(
                "Ctrl+Alt+F2 opens a root shell · q quits this screen",
                Style::default().fg(palette::DIM),
            ),
        ])
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(palette::RED))
                .title(" installation failed "),
        )
        .wrap(Wrap { trim: false }),
        chunks[0],
    );

    let visible = chunks[1].height.saturating_sub(2) as usize;
    let tail: Vec<Line> = app
        .log
        .iter()
        .rev()
        .take(visible)
        .rev()
        .map(|l| Line::raw(l.clone()))
        .collect();
    frame.render_widget(
        Paragraph::new(tail).block(Block::default().borders(Borders::ALL).title(" log tail ")),
        chunks[1],
    );
}

fn input_lines(prompt: &str, input: &str, mask: bool) -> Vec<Line<'static>> {
    let shown = if mask {
        "•".repeat(input.chars().count())
    } else {
        input.to_string()
    };
    vec![
        Line::default(),
        Line::raw(format!("  {prompt}")),
        Line::default(),
        Line::styled(format!("  > {shown}█"), Style::default().fg(palette::CYAN)),
    ]
}

fn centered(r: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(r.width);
    let h = h.min(r.height);
    Rect {
        x: r.x + (r.width - w) / 2,
        y: r.y + (r.height - h) / 2,
        width: w,
        height: h,
    }
}
