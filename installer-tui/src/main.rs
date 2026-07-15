use dots_installer::{app, disks, install, ui};

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

fn main() -> anyhow::Result<()> {
    let disks = disks::list_disks().unwrap_or_default();
    let mut app = app::App::new(disks);
    app.config.swap_size_gib = install::swap_size_from_meminfo(
        &std::fs::read_to_string("/proc/meminfo").unwrap_or_default(),
    );

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
