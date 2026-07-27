use dots_installer::{app, disks, input, install, net, ui};

use std::io;
use std::sync::mpsc;
use std::time::Duration;

use crossterm::event::{self, Event as CEvent, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

/// Throwaway bridge: crossterm's `KeyCode` → the engine-agnostic shim. The
/// whole file is rewritten onto abstracttui in a later task; this just keeps
/// the binary compiling while `app::handle_key` already speaks `input::KeyEvent`.
fn map_key(code: crossterm::event::KeyCode) -> Option<input::KeyCode> {
    use crossterm::event::KeyCode as C;
    use dots_installer::input::KeyCode as I;
    match code {
        C::Char(c) => Some(I::Char(c)),
        C::Enter => Some(I::Enter),
        C::Esc => Some(I::Esc),
        C::Backspace => Some(I::Backspace),
        C::Up => Some(I::Up),
        C::Down => Some(I::Down),
        _ => None,
    }
}

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
    let mut app = app::App::new(disks, auto);
    app.config.swap_size_gib = swap_size_gib;

    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen)?;
    // Restore the terminal even if we panic, so the tty is usable.
    let orig_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
        orig_hook(info);
    }));

    // Restore the terminal on BOTH exits of the loop — clean and Err — so a
    // draw/poll io error can't strand the tty in raw mode + alt screen.
    let result = event_loop(&mut app);
    let _ = disable_raw_mode();
    let _ = execute!(io::stdout(), LeaveAlternateScreen);
    result?;

    if app.reboot && std::env::var("DOTS_INSTALLER_DRY_RUN").is_err() {
        let _ = std::process::Command::new("systemctl")
            .arg("reboot")
            .status();
    }
    Ok(())
}

fn event_loop(app: &mut app::App) -> anyhow::Result<()> {
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let (tx, rx) = mpsc::channel();
    let (net_tx, net_rx) = mpsc::channel();
    let mut runner_started = false;

    while !app.should_quit {
        terminal.draw(|f| ui::draw(f, app))?;

        if app.start_install && !runner_started {
            runner_started = true;
            let cfg = app.config.clone();
            let tx = tx.clone();
            std::thread::spawn(move || install::run(cfg, tx));
        }

        while let Ok(ev) = rx.try_recv() {
            app.on_install_event(ev);
        }

        if let Some(op) = app.pending_net_op.take() {
            let tx = net_tx.clone();
            std::thread::spawn(move || net::run_op(op, &tx));
        }
        while let Ok(ev) = net_rx.try_recv() {
            app.on_net_event(ev);
        }

        if event::poll(Duration::from_millis(100))? {
            if let CEvent::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press {
                    if let Some(code) = map_key(k.code) {
                        app.handle_key(input::KeyEvent::from(code));
                    }
                }
            }
        }
    }
    Ok(())
}
