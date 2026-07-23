//! Binary entry point: argument dispatch, the terminal setup, and the event
//! loop. The apply+tint and the preview decode run on worker threads (the
//! stated requirement that wallpaper selection not block on wallpaper
//! rendering); results flow back over mpsc channels the TUI drains each
//! frame. Mirrors `installer-tui/src/main.rs`.

use std::io;
use std::sync::mpsc;
use std::time::Duration;

use clap::Parser;
use crossterm::event::{self, Event as CEvent, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use wallpaper_tui::app::{App, Event, PendingOp};
use wallpaper_tui::awww::{apply_wallpaper, LiveAwww};
use wallpaper_tui::cli::{self, Args};
use wallpaper_tui::config::{Config, State};
use wallpaper_tui::preview;
use wallpaper_tui::tint;
use wallpaper_tui::ui;

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let config = Config::load();
    let state = State::load();

    if args.restore {
        std::process::exit(cli::restore_all(&config, &state, args.no_tint));
    }
    if args.cache_previews {
        return cli::run_cache(&config, &args.preview_size);
    }
    if let Some(path) = args.path.clone() {
        let output = args
            .output
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--output is required when a path is given"))?;
        return cli::apply_noninteractive(
            &config,
            &mut { state },
            &output,
            &path,
            &args.mode,
            &args.color,
            args.no_tint,
        );
    }

    // Interactive TUI.
    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen)?;
    // Restore the terminal even on panic so the tty stays usable.
    let orig_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        orig_hook(info);
    }));

    let result = run_tui(config, state, args.no_tint);
    let _ = disable_raw_mode();
    let _ = execute!(io::stdout(), LeaveAlternateScreen);
    result
}

fn run_tui(config: Config, state: State, no_tint: bool) -> anyhow::Result<()> {
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;

    // Auto-detect the terminal's image protocol + font size (Kitty graphics on
    // Kitty/Ghostty, Sixel/iTerm2 elsewhere). Must run after the alternate
    // screen + raw mode are entered so the DCS capability query rides on raw
    // stdio (it bypasses crossterm, so there's no ACK race with the event
    // loop). If the terminal doesn't answer (piped output, a dumb terminal,
    // Alacritty with no image protocol), fall back to unicode half-blocks at a
    // fixed font size so a recognizable preview still renders.
    let picker = ratatui_image::picker::Picker::from_query_stdio().unwrap_or_else(|_| {
        let mut p = ratatui_image::picker::Picker::from_fontsize((7, 14));
        p.set_protocol_type(ratatui_image::picker::ProtocolType::Halfblocks);
        p
    });

    let mut app = App::new(config, state, no_tint, picker);
    // Kick off the preview for the initial selection.
    app.request_preview();

    let (apply_tx, apply_rx) = mpsc::channel::<Event>();
    let (preview_tx, preview_rx) = mpsc::channel::<Event>();

    while !app.should_quit {
        terminal.draw(|f| ui::draw(f, &mut app))?;

        // Drain worker results.
        while let Ok(ev) = apply_rx.try_recv() {
            app.on_event(ev);
        }
        while let Ok(ev) = preview_rx.try_recv() {
            app.on_event(ev);
        }

        // Dispatch any pending op onto a worker thread.
        if let Some(op) = app.pending.take() {
            match op {
                PendingOp::Apply {
                    group,
                    transition_type,
                    transition_duration,
                    no_tint,
                } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        let groups = vec![group.clone()];
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let status = tint::apply_tint(&group.path, no_tint);
                        let msg = match status {
                            Some(s) => format!("applied {} (tint {})", group.path, s.qt),
                            None => format!("applied {}", group.path),
                        };
                        let _ = tx.send(Event::ApplyDone { msg });
                    });
                }
                PendingOp::Restore {
                    groups,
                    transition_type,
                    transition_duration,
                    no_tint,
                } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let tint_path = groups.first().map(|g| g.path.as_str()).unwrap_or("");
                        let status = if tint_path.is_empty() {
                            None
                        } else {
                            tint::apply_tint(tint_path, no_tint)
                        };
                        let msg = match status {
                            Some(s) => format!("restored {} (tint {})", groups.len(), s.qt),
                            None => format!("restored {} output(s)", groups.len()),
                        };
                        let _ = tx.send(Event::ApplyDone { msg });
                    });
                }
                PendingOp::Preview { path } => {
                    let tx = preview_tx.clone();
                    std::thread::spawn(move || {
                        let image = preview::load_preview(&path).ok();
                        let _ = tx.send(Event::PreviewReady { path, image });
                    });
                }
            }
        }

        if event::poll(Duration::from_millis(100))? {
            if let CEvent::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press {
                    app.handle_key(k);
                }
            }
        }
    }
    Ok(())
}
