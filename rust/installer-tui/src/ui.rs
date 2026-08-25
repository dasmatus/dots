//! abstracttui view — a pure projection of `&App` onto a View tree. No I/O
//! lives here; reactivity comes from `dyn_view` re-reading the `Signal<App>` on
//! change. All user-visible strings are copied verbatim from the previous
//! ratatui view so the wizard reads identically.

use abstracttui::prelude::*;
use abstracttui::render::{RichLine, RichText, Span, Style as Ink};
use abstracttui::ui::UiEvent;
use abstracttui::widgets::{Progress, RichTextView};

use crate::app::{App, Screen};
use crate::fx::ScreenFx;
use crate::input::{self, KeyCode};

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

/// Root component: one `dyn_view` that re-reads `app` and `fx` and dispatches
/// by `Screen`, plus a root `on_event` that bridges engine key events into the
/// pure `App` state machine. `fx` supplies the animated panel slide + error
/// shake; `installing_view` reads its eased progress ratio.
#[must_use]
pub fn root_view(app: Signal<App>, fx: Signal<ScreenFx>) -> View {
    let tokens = TokenSet::default();
    Element::new()
        .style(LayoutStyle::fill())
        .child(dyn_view(LayoutStyle::fill(), move || {
            let a = app.get();
            fx.with(|f| wizard_view(&a, f, &tokens))
        }))
        .on_event(move |_, ev| {
            let UiEvent::Key(k) = ev else {
                return;
            };
            let Some(code) = map_key(k.key) else {
                return;
            };
            // Detect screen / error transitions across the key press so the
            // animation overlay can retarget in lockstep with the state change.
            let prev_screen = app.with_untracked(|a| a.screen);
            let prev_error = app.with_untracked(|a| a.error.clone());
            app.update(|a| a.handle_key(input::KeyEvent::from(code)));
            let (screen, error) = app.with_untracked(|a| (a.screen, a.error.clone()));
            if screen != prev_screen {
                fx.update(|f| f.retarget_screen(0.0));
            }
            if error.is_some() && error != prev_error {
                fx.update(ScreenFx::shake);
            }
        })
        .build()
}

/// Map the engine's `Key` to the wizard's `input::KeyCode`. Unknown keys map
/// to `None` — the wizard ignores them. Only the keys `handle_key` reacts to
/// are forwarded, so the engine's focus traversal etc. is undisturbed.
fn map_key(k: Key) -> Option<KeyCode> {
    Some(match k {
        Key::Char(c) => KeyCode::Char(c),
        Key::Enter => KeyCode::Enter,
        Key::Escape => KeyCode::Esc,
        Key::Backspace => KeyCode::Backspace,
        Key::Up => KeyCode::Up,
        Key::Down => KeyCode::Down,
        _ => return None,
    })
}

/// The wizard shell: every screen renders as a bordered panel, offset by the
/// animated `fx` shake (and, later, the screen slide) so errors literally
/// shake the panel and screen changes slide it.
#[allow(clippy::too_many_lines)]
fn wizard_view(a: &App, fx: &ScreenFx, tokens: &TokenSet) -> View {
    let panel = wizard_panel(a, fx, tokens);
    let shake = fx.shake_x();
    if shake == 0 {
        panel
    } else {
        // Translate the whole panel by the shake offset: absolute-position
        // the fill wrapper with `left = shake`, so the panel shifts right
        // (and back) as the damped sine runs.
        Element::new()
            .style(LayoutStyle::fill().absolute(Inset {
                left: Some(shake),
                ..Inset::default()
            }))
            .child(panel)
            .build()
    }
}

/// Per-screen panel body (before the shake translate is applied).
fn wizard_panel(a: &App, fx: &ScreenFx, tokens: &TokenSet) -> View {
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
        Screen::Ai => ai_view(a, tokens),
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

        Screen::Installing => installing_view(a, fx, tokens),
        Screen::Failed => failed_view(a, tokens),
        Screen::Done => done_view(a, tokens),
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
        span_line(
            format!(
                "    ai        claude {} · codex {} · ollama {}",
                on_off(app.config.ai_claude),
                on_off(app.config.ai_codex),
                on_off(app.config.ai_ollama),
            ),
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

/// The `Ai` screen: a three-row toggle list (Claude Code, Codex CLI, Ollama)
/// with ASCII `[x]`/`[ ]` markers and a `▶`/` ` cursor — same tty1-safe style
/// as `disk_select_view`. The toggles map 1:1 to `config.ai_claude` /
/// `ai_codex` / `ai_ollama`, rendered into settings.nix as aiClaude/aiCodex/
/// aiOllama and bridged to options.dots.ai.* (nix/modules/dots.nix) which gate
/// nix/home/{claude,codex}.nix + the ollama service.
fn ai_view(app: &App, tokens: &TokenSet) -> View {
    let opts: [(&str, bool); crate::app::AI_OPTIONS] = [
        ("Claude Code", app.config.ai_claude),
        ("Codex CLI", app.config.ai_codex),
        ("Ollama", app.config.ai_ollama),
    ];
    let mut lines = vec![
        blank(),
        span_line("  Select AI tooling to enable:", Ink::new()),
        span_line(
            "  (written to settings.nix as aiClaude/aiCodex/aiOllama)",
            Ink::new().fg(palette::DIM),
        ),
        blank(),
    ];
    for (i, (label, on)) in opts.iter().enumerate() {
        let cursor = if i == app.ai_selected { "▶" } else { " " };
        let mark = if *on { "[x]" } else { "[ ]" };
        let ink = if i == app.ai_selected {
            Ink::new().fg(palette::CYAN).bold()
        } else {
            Ink::new()
        };
        lines.push(span_line(format!(" {cursor} {mark} {label}"), ink));
    }
    lines.push(blank());
    lines.push(span_line(
        "↑/↓ move · Space toggle · Enter confirm · Esc back",
        Ink::new().fg(palette::DIM),
    ));
    push_error(&mut lines, app);
    block_view(" ai ", lines, tokens)
}

/// The Installing screen: a cyan `step i/n — title` label, the engine's
/// `Progress` bar (sub-cell eighth-block fill), and a dim log that fills the
/// rest of the panel. The bar reads the eased ratio from `fx.progress_r()`
/// when animations are on (the loop retargets `fx` on each step change and
/// ticks it per frame), else the raw step ratio.
#[allow(clippy::cast_precision_loss)]
fn installing_view(app: &App, fx: &ScreenFx, tokens: &TokenSet) -> View {
    let raw = if app.total_steps == 0 {
        0.0
    } else {
        (app.current_step as f32 / app.total_steps as f32).clamp(0.0, 1.0)
    };
    let ratio = if crate::fx::animations_enabled() {
        fx.progress_r()
    } else {
        raw
    };
    let label = RichTextView::new(RichText::from_lines(vec![span_line(
        format!(
            "step {}/{} — {}",
            app.current_step, app.total_steps, app.step_title
        ),
        Ink::new().fg(palette::CYAN),
    )]))
    .element(tokens);
    let bar = Progress::new(ratio).element(tokens);
    // The log pane grows to fill the remaining panel height. Feed a generous
    // tail of the retained log (app keeps ≤1000 lines) so the frame is dense
    // rather than eight sparse lines under empty space. Newest lines win when
    // the tail is longer than the pane; the layout clips the overflow.
    const LOG_TAIL: usize = 200;
    let log_lines: Vec<RichLine> = app
        .log
        .iter()
        .rev()
        .take(LOG_TAIL)
        .rev()
        .map(|l| span_line(l.clone(), Ink::new().fg(palette::DIM)))
        .collect();
    let log = RichTextView::new(RichText::from_lines(log_lines)).element(tokens);

    // Column that fills the panel: label (1 row, full width), bar (1 row, full
    // width), log (fills the rest). Each child is wrapped in an Element with an
    // explicit layout so the auto-measuring rich-text views don't collapse.
    let body = Element::new()
        .style(
            LayoutStyle::column()
                .width(Dimension::Percent(1.0))
                .height(Dimension::Percent(1.0))
                .gap(1),
        )
        .child(
            Element::new()
                .style(LayoutStyle::line(1))
                .child(label.into())
                .build(),
        )
        .child(
            Element::new()
                .style(LayoutStyle::line(1))
                .child(bar.into())
                .build(),
        )
        .child(
            Element::new()
                .style(
                    LayoutStyle::default()
                        .width(Dimension::Percent(1.0))
                        .height(Dimension::Percent(1.0))
                        .grow(1.0),
                )
                .child(log.into())
                .build(),
        )
        .build();

    Block::new()
        .border(BorderKind::Rounded)
        .title(" installing ")
        .layout(LayoutStyle::fill())
        .child(body)
        .element(tokens)
        .into()
}

/// The Failed screen: the error message in red bold, a Ctrl+Alt+F2 hint, and a
/// plain log tail. `q`/Enter/Esc all quit (handled by the state machine).
fn failed_view(app: &App, tokens: &TokenSet) -> View {
    let msg = app.error.as_deref().unwrap_or("unknown error");
    let mut lines = vec![
        blank(),
        span_line(msg.to_string(), Ink::new().fg(palette::RED).bold()),
        blank(),
        span_line(
            "Ctrl+Alt+F2 opens a root shell · q quits this screen",
            Ink::new().fg(palette::DIM),
        ),
        blank(),
    ];
    for l in app.log.iter().rev().take(6).rev() {
        lines.push(span_line(l.clone(), Ink::new()));
    }
    block_view(" installation failed ", lines, tokens)
}

/// The Done screen: a green "Installation finished." header, the LUKS recovery
/// key in yellow bold (with the "write it down" warning), and the reboot hint.
fn done_view(app: &App, tokens: &TokenSet) -> View {
    let key = app.recovery_key.as_deref().unwrap_or("(missing)");
    let lines = vec![
        blank(),
        span_line(
            "  Installation finished.",
            Ink::new().fg(palette::GREEN).bold(),
        ),
        blank(),
        span_line(
            "  LUKS recovery key (also in /root/luks-recovery.txt",
            Ink::new(),
        ),
        span_line("  on the installed system) — WRITE IT DOWN:", Ink::new()),
        blank(),
        span_line(format!("    {key}"), Ink::new().fg(palette::YELLOW).bold()),
        blank(),
        span_line(
            "  Remove the installation medium, then press Enter to reboot.",
            Ink::new(),
        ),
        blank(),
        span_line("Enter reboot", Ink::new().fg(palette::DIM)),
    ];
    block_view(" installed ", lines, tokens)
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

/// `true` → "on", `false` → "off" for the confirm-screen AI summary.
fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}

/// An empty line (vertical spacer).
fn blank() -> RichLine {
    RichLine::new()
}
