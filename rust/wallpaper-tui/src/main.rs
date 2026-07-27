//! Binary entry point: argument dispatch, the terminal setup, and the
//! abstracttui event loop. The apply+tint and the preview decode run on worker
//! threads (wallpaper selection must not block on rendering); results flow
//! back over mpsc channels the loop drains each frame. The key bridge lives in
//! `ui::root_view`'s `on_event` (it calls `App::handle_key`); this file hosts
//! the `Signal<App>` / `Signal<Fx>`, drains the workers, dispatches pending ops,
//! advances the `Fx` crossfade one frame per turn, and paces the loop. The
//! non-interactive CLI paths (`--restore`, `--cache-previews`, `--path`) are
//! unchanged from the ratatui era.

use std::cell::RefCell;
use std::rc::Rc;
use std::str::FromStr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use abstracttui::anim::Clock;
use abstracttui::app::{App as Engine, Driver, RunConfig};
use abstracttui::prelude::*;
use abstracttui::term::{have_tty, Terminal, UnixTerminal};

use clap::Parser;

use wallpaper_tui::accent::TintBackend;
use wallpaper_tui::app::{App, Event, PendingOp};
use wallpaper_tui::awww::{apply_wallpaper, LiveAwww};
use wallpaper_tui::cli::{self, Args};
use wallpaper_tui::config::{Config, State};
use wallpaper_tui::fx::Fx;
use wallpaper_tui::preview;
use wallpaper_tui::tint;
use wallpaper_tui::ui;

fn resolve_backend(args_backend: Option<String>, config_backend: &str) -> TintBackend {
    if let Some(b) = args_backend {
        if let Ok(backend) = TintBackend::from_str(&b) {
            return backend;
        }
    }
    TintBackend::from_str(config_backend).unwrap_or_default()
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let config = Config::load();
    let state = State::load();
    let backend = resolve_backend(args.tint_backend.clone(), &config.tint_backend);

    if args.restore {
        std::process::exit(cli::restore_all(&config, &state, args.no_tint, backend));
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
            backend,
        );
    }

    run_tui(config, state, args.no_tint, backend)
}

/// Host `app_state` in the engine and drive the loop until the picker quits.
fn run_tui(
    config: Config,
    state: State,
    no_tint: bool,
    backend: TintBackend,
) -> anyhow::Result<()> {
    if !have_tty() {
        anyhow::bail!("wallpaper TUI needs a tty (run on a real console)");
    }

    let mut app_state = App::new(config, state, no_tint, backend);
    // Kick off the preview for the initial selection before the state moves
    // into the signal; the first loop iteration dispatches the resulting
    // `PendingOp::Preview`.
    app_state.request_preview();

    let (apply_tx, apply_rx) = mpsc::channel::<Event>();
    let (preview_tx, preview_rx) = mpsc::channel::<Event>();

    let mut term = UnixTerminal::new()?;
    let viewport = term.size().unwrap_or_else(|_| Size::new(80, 24));
    let mut engine = Engine::new(viewport);

    // Signals are created inside `mount`'s closure (where the root `Scope`
    // lives); smuggle the `Copy` handles out through slots so the loop can
    // drain workers and dispatch ops into the app state from outside.
    let app_slot: Rc<RefCell<Option<Signal<App>>>> = Rc::new(RefCell::new(None));
    let fx_slot: Rc<RefCell<Option<Signal<Fx>>>> = Rc::new(RefCell::new(None));
    let app_slot2 = app_slot.clone();
    let fx_slot2 = fx_slot.clone();
    engine.mount(move |cx| {
        let a = cx.signal(app_state);
        let f = cx.signal(Fx::new(Clock::real()));
        *app_slot2.borrow_mut() = Some(a);
        *fx_slot2.borrow_mut() = Some(f);
        ui::root_view(a, f)
    })?;
    let app_sig = app_slot.take().expect("app signal mounted");
    let fx_sig = fx_slot.take().expect("fx signal mounted");

    let mut driver = Driver::new(&mut engine, &mut term, RunConfig::default())?;
    // Idle wait cap: worker results land within ~50 ms even with no key input.
    // A frame request from `Fx` (crossfade in flight) wakes this early, so the
    // fade runs at full speed and idle polls cheaply.
    let poll = Duration::from_millis(50);

    loop {
        // 1. Drain apply + preview worker results into the app state.
        drain(&apply_rx, &app_sig);
        drain(&preview_rx, &app_sig);

        // 2. Advance the crossfade overlay one frame (no-op when settled).
        fx_sig.update(Fx::tick);

        // 3. Dispatch any pending op the state machine queued via `handle_key`
        //    (or the initial `request_preview` above) onto a worker thread.
        let mut pending = None;
        app_sig.update(|a| pending = a.pending.take());
        if let Some(op) = pending {
            match op {
                PendingOp::Apply {
                    group,
                    transition_type,
                    transition_duration,
                    no_tint,
                    backend,
                } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        let groups = vec![group.clone()];
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let status = tint::apply_tint(&group.path, no_tint, backend);
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
                    backend,
                } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let tint_path = groups.first().map_or("", |g| g.path.as_str());
                        let status = if tint_path.is_empty() {
                            None
                        } else {
                            tint::apply_tint(tint_path, no_tint, backend)
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

        // 4. Pump the engine: process input (the `on_event` key bridge calls
        //    `handle_key`), run effects, layout, render.
        let turn = driver.turn(&mut engine, &mut term)?;

        // 5. Quit when the state machine asks for it.
        if app_sig.with_untracked(|a| a.should_quit) {
            break;
        }

        // 6. Pace: when idle, block for input OR the poll deadline (whichever
        //    is first). Keeps the loop off the CPU between events.
        if turn.idle {
            driver.wait_until(&mut term, Instant::now() + poll)?;
        }
    }

    driver.finish(&mut term)?;
    Ok(())
}

/// Drain worker events into the app state. A `PreviewReady` for a new path
/// changes the on-screen bitmap; the view re-renders reactively via the
/// `Signal<App>` it already reads.
fn drain(rx: &mpsc::Receiver<Event>, app_sig: &Signal<App>) {
    while let Ok(ev) = rx.try_recv() {
        app_sig.update(|a| a.on_event(ev));
    }
}
