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

        // Filled in by later tasks (lists + install/done/failed).
        Screen::Network => block_view(
            " network ",
            vec![span_line("Wi-Fi setup".to_string(), Ink::new())],
            tokens,
        ),
        Screen::DiskSelect => block_view(
            " target disks ",
            vec![span_line("Select target disks".to_string(), Ink::new())],
            tokens,
        ),
        Screen::WifiConnecting => block_view(
            " connecting ",
            vec![span_line(
                "connecting…".to_string(),
                Ink::new().fg(palette::CYAN),
            )],
            tokens,
        ),
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
