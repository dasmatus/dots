//! Entry point — the installer wizard on the abstracttui runtime.
//!
//! The pure `App` state machine lives in `crate::app`; here we host it in a
//! `Signal<App>`, mount `ui::root_view`, and run a custom `Driver` loop that
//! drains the install/net worker channels into `on_install_event` /
//! `on_net_event`, dispatches `pending_net_op` / `start_install` to worker
//! threads, advances the `ScreenFx` animation overlay one frame per turn, and
//! pumps engine key events through `root_view`'s `on_event` key bridge into
//! `handle_key`. The loop quits when the state machine sets `should_quit`;
//! the reboot side effect fires only outside a dry run.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use abstracttui::anim::Clock;
use abstracttui::app::{App as Engine, Driver, RunConfig};
use abstracttui::prelude::*;
use abstracttui::term::{have_tty, Terminal, UnixTerminal};

use dots_installer::{app, disks, fx::ScreenFx, install, net, ui};

fn main() -> anyhow::Result<()> {
    let swap_size_gib = install::swap_size_from_meminfo(
        &std::fs::read_to_string("/proc/meminfo").unwrap_or_default(),
    );
    // Best-effort autodetection: when one fixed disk is large enough we skip
    // the picker, but any failure (ambiguous disks, all too small, lsblk error)
    // falls back to the manual DiskSelect screen instead of aborting before
    // the TUI ever renders — which would otherwise crash-loop on a blank tty1.
    let disks = disks::list_disks().unwrap_or_default();
    let auto = disks::autodetect_disk(&disks, swap_size_gib)
        .ok()
        .map(|disk| disk.path);
    let mut app_state = app::App::new(disks, auto);
    app_state.config.swap_size_gib = swap_size_gib;

    run(app_state)?;
    Ok(())
}

/// Host `app_state` in the engine and drive the loop until the wizard quits.
fn run(app_state: app::App) -> anyhow::Result<()> {
    if !have_tty() {
        anyhow::bail!("installer TUI needs a tty (run on a real console)");
    }

    let (tx, rx) = mpsc::channel();
    let (net_tx, net_rx) = mpsc::channel();
    let runner_started = AtomicBool::new(false);

    let mut term = UnixTerminal::new()?;
    let viewport = term.size().unwrap_or_else(|_| Size::new(80, 24));
    let mut engine = Engine::new(viewport);

    // Signals are created inside `mount`'s closure (that's where the root
    // `Scope` lives); smuggle the `Copy` handles out through a slot so the
    // loop can drain workers and dispatch ops into the app state from outside.
    let app_slot: Rc<RefCell<Option<Signal<app::App>>>> = Rc::new(RefCell::new(None));
    let fx_slot: Rc<RefCell<Option<Signal<ScreenFx>>>> = Rc::new(RefCell::new(None));
    let app_slot2 = app_slot.clone();
    let fx_slot2 = fx_slot.clone();
    engine.mount(move |cx| {
        let a = cx.signal(app_state);
        let f = cx.signal(ScreenFx::new(Clock::real()));
        *app_slot2.borrow_mut() = Some(a);
        *fx_slot2.borrow_mut() = Some(f);
        ui::root_view(a, f)
    })?;
    let app_sig = app_slot.take().expect("app signal mounted");
    let fx_sig = fx_slot.take().expect("fx signal mounted");

    let mut driver = Driver::new(&mut engine, &mut term, RunConfig::default())?;
    // Idle wait cap: worker results land within ~50 ms even with no key input.
    // A frame request from `ScreenFx` (animation in flight) wakes this early,
    // so motion runs at full speed and idle polls cheaply.
    let poll = Duration::from_millis(50);

    loop {
        // 1. Drain install + net worker results; retarget the panel slide when
        //    a worker-driven screen transition lands (Done / Failed / connect).
        drain_install(&rx, &app_sig, &fx_sig);
        drain_net(&net_rx, &app_sig, &fx_sig);

        // 2. Advance the animation overlay one frame (no-op when settled).
        fx_sig.update(ScreenFx::tick);

        // 3. Dispatch the install runner (once) and any pending net op the
        //    state machine queued via `handle_key`.
        if app_sig.with_untracked(|a| a.start_install)
            && !runner_started.swap(true, Ordering::SeqCst)
        {
            let cfg = app_sig.with_untracked(|a| a.config.clone());
            let tx = tx.clone();
            std::thread::spawn(move || install::run(cfg, tx));
        }
        let mut pending_op = None;
        app_sig.update(|a| pending_op = a.pending_net_op.take());
        if let Some(op) = pending_op {
            let net_tx = net_tx.clone();
            std::thread::spawn(move || net::run_op(op, &net_tx));
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

    if app_sig.with_untracked(|a| a.reboot) && std::env::var("DOTS_INSTALLER_DRY_RUN").is_err() {
        let _ = std::process::Command::new("systemctl")
            .arg("reboot")
            .status();
    }
    Ok(())
}

/// Drain install worker events into the app state, retargeting the slide on
/// any screen transition.
fn drain_install(
    rx: &mpsc::Receiver<install::Event>,
    app_sig: &Signal<app::App>,
    fx_sig: &Signal<ScreenFx>,
) {
    while let Ok(ev) = rx.try_recv() {
        let prev = app_sig.with_untracked(|a| a.screen);
        app_sig.update(|a| a.on_install_event(ev));
        if app_sig.with_untracked(|a| a.screen) != prev {
            fx_sig.update(|f| f.retarget_screen(0.0));
        }
    }
}

/// Drain net worker events into the app state, retargeting the slide on any
/// screen transition.
fn drain_net(
    net_rx: &mpsc::Receiver<net::Event>,
    app_sig: &Signal<app::App>,
    fx_sig: &Signal<ScreenFx>,
) {
    while let Ok(ev) = net_rx.try_recv() {
        let prev = app_sig.with_untracked(|a| a.screen);
        app_sig.update(|a| a.on_net_event(ev));
        if app_sig.with_untracked(|a| a.screen) != prev {
            fx_sig.update(|f| f.retarget_screen(0.0));
        }
    }
}
