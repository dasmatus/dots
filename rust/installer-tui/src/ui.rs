//! abstracttui view — a pure projection of `&App` onto a View tree. No I/O
//! lives here; reactivity comes from `dyn_view` re-reading the `Signal<App>` on
//! change. All user-visible strings are copied verbatim from the previous
//! ratatui view so the wizard reads identically.

use abstracttui::prelude::*;
use abstracttui::render::{RichLine, RichText, Span, Style as Ink};
use abstracttui::widgets::RichTextView;

use crate::app::{App, Screen};
use crate::fx::ScreenFx;

/// Tokyonight (night) palette as engine `Rgba` values — no hex arithmetic in
/// widget code (the engine's `no_color_arithmetic_in_widgets` rule).
pub mod palette {
    use abstracttui::prelude::Rgba;

    pub const BG: Rgba = Rgba::rgb(0x1a, 0x1b, 0x26);
    pub const FG: Rgba = Rgba::rgb(0xc0, 0xca, 0xf5);
    pub const BLUE: Rgba = Rgba::rgb(0x7a, 0xa2, 0xf7);
    pub const CYAN: Rgba = Rgba::rgb(0x7d, 0xcf, 0xff);
    pub const GREEN: Rgba = Rgba::rgb(0x9e, 0xce, 0x6a);
    pub const MAGENTA: Rgba = Rgba::rgb(0xbb, 0x9a, 0xf7);
    pub const RED: Rgba = Rgba::rgb(0xf7, 0x76, 0x8e);
    pub const YELLOW: Rgba = Rgba::rgb(0xe0, 0xaf, 0x68);
    pub const DIM: Rgba = Rgba::rgb(0x56, 0x5f, 0x89);
}

/// Root component: one `dyn_view` that re-reads `app` and dispatches by
/// `Screen`. `fx` is wired into the install/done screens by a later task.
#[must_use]
pub fn root_view(app: Signal<App>, _fx: Signal<ScreenFx>) -> View {
    let tokens = TokenSet::default();
    Element::new()
        .style(LayoutStyle::fill())
        .child(dyn_view(LayoutStyle::fill(), move || {
            let a = app.get();
            wizard_view(&a, &tokens)
        }))
        .build()
}

/// The wizard shell: every screen renders as a centered bordered panel with a
/// styled prompt body, an input line with a cursor glyph, a dim hint, and an
/// optional red error line.
#[allow(clippy::too_many_lines)]
fn wizard_view(a: &App, tokens: &TokenSet) -> View {
    match a.screen {
        Screen::Welcome => welcome_view(a, tokens),

        Screen::Hostname => prompt_screen(
            " hostname ",
            "Hostname (empty = \"tokyonight\"):",
            &a.input,
            false,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::Username => prompt_screen(
            " user ",
            "Username for the primary user:",
            &a.input,
            false,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::GitName => prompt_screen(
            " git identity ",
            "Git user.name (commits will be signed with this):",
            &a.input,
            false,
            "Enter confirm · Esc back",
            a,
            tokens,
        ),
        Screen::GitEmail => prompt_screen(
            " git identity ",
            "Git user.email:",
            &a.input,
            false,
            "Enter confirm · Esc back",
            a,
            tokens,
        ),
        Screen::RootPassword => prompt_screen(
            " root password ",
            "Root password (also the LUKS fallback passphrase):",
            &a.input,
            true,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::RootPasswordConfirm => prompt_screen(
            " root password ",
            "Repeat root password:",
            &a.input,
            true,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::UserPassword => prompt_screen(
            " user password ",
            "User password:",
            &a.input,
            true,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::UserPasswordConfirm => prompt_screen(
            " user password ",
            "Repeat user password:",
            &a.input,
            true,
            "Enter confirm",
            a,
            tokens,
        ),
        Screen::WifiPassword => prompt_screen(
            " Wi-Fi passphrase ",
            &format!("Passphrase for \"{}\":", a.wifi_ssid),
            &a.input,
            true,
            "Enter connect · Esc back",
            a,
            tokens,
        ),

        Screen::Confirm => confirm_view(a, tokens),

        Screen::Network => network_view(a, tokens),
        Screen::DiskSelect => disk_select_view(a, tokens),
        Screen::WifiConnecting => wifi_connecting_view(a, tokens),

        // Filled in by a later task (Progress + log tail).
        Screen::Installing => block_view(
            " installing ",
            vec![span_line("installing…".to_string(), Ink::new())],
            tokens,
        ),
        Screen::Failed => block_view(
            " installation failed ",
            vec![span_line("failed".to_string(), Ink::new().fg(palette::RED))],
            tokens,
        ),
        Screen::Done => block_view(
            " installed ",
            vec![span_line("done".to_string(), Ink::new().fg(palette::GREEN))],
            tokens,
        ),
    }
}

/// The Welcome screen: title + intro blurb + hint.
fn welcome_view(app: &App, tokens: &TokenSet) -> View {
    let mut lines = vec![
        blank(),
        span_line(
            "  NixOS · TPM2-encrypted btrfs · i3 + Hyprland · Tokyonight",
            Ink::new().fg(palette::MAGENTA),
        ),
        blank(),
        span_line(
            "  This wizard ERASES the selected disk(s) and installs the",
            Ink::new(),
        ),
        span_line(
            "  NixOS system from the flake bundled with this ISO.",
            Ink::new(),
        ),
        blank(),
        span_line("Enter continue · Esc quit", Ink::new().fg(palette::DIM)),
    ];
    push_error(&mut lines, app);
    block_view("tokyonight-dots installer", lines, tokens)
}

/// The point-of-no-return confirmation screen.
fn confirm_view(app: &App, tokens: &TokenSet) -> View {
    let mut lines = vec![
        blank(),
        span_line(
            format!(
                "  ALL DATA on {} will be permanently erased!",
                app.config.disks.join(", ")
            ),
            Ink::new().fg(palette::RED).bold(),
        ),
        blank(),
        span_line(
            format!("    disks     {}", app.config.disks.join(", ")),
            Ink::new(),
        ),
        span_line(format!("    hostname  {}", app.config.hostname), Ink::new()),
        span_line(format!("    user      {}", app.config.username), Ink::new()),
        span_line(
            format!(
                "    git       {} <{}>",
                app.config.git_name, app.config.git_email
            ),
            Ink::new(),
        ),
        span_line(
            format!("    swap      {}G", app.config.swap_size_gib),
            Ink::new(),
        ),
        blank(),
        span_line("  Type ERASE to proceed:".to_string(), Ink::new()),
        span_line(format!("  > {}", app.input), Ink::new().fg(palette::YELLOW)),
        blank(),
        span_line("Enter proceed · Esc back", Ink::new().fg(palette::DIM)),
    ];
    push_error(&mut lines, app);
    block_view(" point of no return ", lines, tokens)
}

/// The Network screen: a status line, an optional busy line, then the Wi-Fi
/// list with a `▶` cursor on the selected row and signal-bar + security
/// columns. Hand-rolled as rich text because the engine's `List` widget needs
/// a `Scope` for its element, and the `dyn_view` projection here is pure
/// `&App` with no `cx` in scope.
fn network_view(app: &App, tokens: &TokenSet) -> View {
    let mut lines = vec![
        blank(),
        span_line(
            "  Wi-Fi setup — nixos-install pulls from the binary cache,",
            Ink::new(),
        ),
        span_line(
            "  so get online unless this is the offline (iso-full) image.",
            Ink::new(),
        ),
        blank(),
    ];
    lines.push(match app.online {
        None => span_line(
            "  status: checking…".to_string(),
            Ink::new().fg(palette::DIM),
        ),
        Some(true) => span_line(
            "  status: online ✓".to_string(),
            Ink::new().fg(palette::GREEN),
        ),
        Some(false) => span_line(
            "  status: offline ✗".to_string(),
            Ink::new().fg(palette::YELLOW),
        ),
    });
    if let Some(b) = &app.net_busy {
        lines.push(span_line(format!("  {b}"), Ink::new().fg(palette::CYAN)));
    }
    lines.push(blank());
    if app.wifi_networks.is_empty() && app.net_busy.is_none() {
        lines.push(span_line(
            "  no Wi-Fi networks found (wired is fine too — press s)",
            Ink::new().fg(palette::DIM),
        ));
    }
    for (i, n) in app.wifi_networks.iter().enumerate() {
        let marker = if i == app.wifi_selected {
            "  ▶ "
        } else {
            "    "
        };
        let ink = if i == app.wifi_selected {
            Ink::new().fg(palette::CYAN).bold()
        } else {
            Ink::new()
        };
        let security = if n.is_open() {
            "open"
        } else {
            n.security.as_str()
        };
        lines.push(span_line(
            format!("{}{} {}  {security}", marker, n.signal_bars(), n.ssid),
            ink,
        ));
    }
    lines.push(blank());
    lines.push(span_line(
        "↑/↓ select · Enter connect · r rescan · s skip · Esc back",
        Ink::new().fg(palette::DIM),
    ));
    push_error(&mut lines, app);
    block_view(" network ", lines, tokens)
}

/// The `WifiConnecting` screen: a cyan "connecting to …" line, a dim helper, and
/// a "please wait" hint. No cancel control by design (interrupting nmcli
/// mid-handshake helps nobody).
fn wifi_connecting_view(app: &App, tokens: &TokenSet) -> View {
    let lines = vec![
        blank(),
        span_line(
            format!("  connecting to \"{}\"…", app.wifi_ssid),
            Ink::new().fg(palette::CYAN),
        ),
        blank(),
        span_line(
            "  asking NetworkManager, this can take a few seconds",
            Ink::new().fg(palette::DIM),
        ),
        blank(),
        span_line("please wait", Ink::new().fg(palette::DIM)),
    ];
    block_view(" connecting ", lines, tokens)
}

/// The `DiskSelect` screen: a multi-select list of disks with ASCII `[x]`/`[ ]`
/// membership markers and a `▶`/` ` cursor on the focused row. ASCII markers
/// (not a unicode checkbox) so they render on any Linux VT console font — this
/// TUI runs on raw tty1, not a terminal emulator.
fn disk_select_view(app: &App, tokens: &TokenSet) -> View {
    let mut lines = vec![
        blank(),
        span_line(
            "  Select target disks to span the LVM volume group",
            Ink::new(),
        ),
        span_line("  (each will be ERASED):", Ink::new()),
        blank(),
    ];
    if app.disks.is_empty() {
        lines.push(span_line(
            "  no installable disks found",
            Ink::new().fg(palette::RED),
        ));
    }
    for (i, d) in app.disks.iter().enumerate() {
        let cursor = if i == app.selected { "▶" } else { " " };
        let mark = if *app.picked.get(i).unwrap_or(&false) {
            "[x]"
        } else {
            "[ ]"
        };
        let removable = if d.removable { " [removable]" } else { "" };
        let ink = if i == app.selected {
            Ink::new().fg(palette::CYAN).bold()
        } else {
            Ink::new()
        };
        lines.push(span_line(
            format!(
                " {cursor} {mark} {}  {}  {}{removable}",
                d.path,
                d.human_size(),
                d.model
            ),
            ink,
        ));
    }
    lines.push(blank());
    lines.push(span_line(
        "↑/↓ move · Space toggle · Enter confirm · Esc back",
        Ink::new().fg(palette::DIM),
    ));
    push_error(&mut lines, app);
    block_view(" target disks ", lines, tokens)
}

/// A generic prompt + input-line screen (hostname, passwords, git identity, …).
fn prompt_screen(
    title: &str,
    prompt: &str,
    input: &str,
    mask: bool,
    hint: &str,
    app: &App,
    tokens: &TokenSet,
) -> View {
    let mut lines = input_lines(prompt, input, mask);
    lines.push(blank());
    lines.push(span_line(hint.to_string(), Ink::new().fg(palette::DIM)));
    push_error(&mut lines, app);
    block_view(title, lines, tokens)
}

/// Prompt + masked/echoed input with a block cursor glyph, matching the prior
/// ratatui `input_lines` layout.
fn input_lines(prompt: &str, input: &str, mask: bool) -> Vec<RichLine> {
    let shown = if mask {
        "•".repeat(input.chars().count())
    } else {
        input.to_string()
    };
    vec![
        blank(),
        span_line(format!("  {prompt}"), Ink::new()),
        blank(),
        span_line(format!("  > {shown}█"), Ink::new().fg(palette::CYAN)),
    ]
}

/// Append the red error line (if any) with a leading blank separator.
fn push_error(lines: &mut Vec<RichLine>, app: &App) {
    if let Some(err) = &app.error {
        lines.push(blank());
        lines.push(span_line(format!("  ✗ {err}"), Ink::new().fg(palette::RED)));
    }
}

/// A bordered panel titled `title` holding `lines`. The panel fills its
/// parent so the `RichTextView` body gets a real content area to render into
/// (an auto-sized panel + auto-sized body collapses to zero content width).
fn block_view(title: &str, lines: Vec<RichLine>, tokens: &TokenSet) -> View {
    Block::new()
        .border(BorderKind::Rounded)
        .title(title)
        .layout(LayoutStyle::fill())
        .child(RichTextView::new(RichText::from_lines(lines)).element(tokens))
        .element(tokens)
        .into()
}

/// A single-styled line.
fn span_line(text: impl Into<String>, ink: Ink) -> RichLine {
    RichLine::from_spans(vec![Span::new(text, ink)])
}

/// An empty line (vertical spacer).
fn blank() -> RichLine {
    RichLine::new()
}
