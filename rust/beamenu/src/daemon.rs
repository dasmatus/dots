//! The resident daemon: bus name, UI host and clipboard watcher.
//!
//! Wayland gives no way to poll the clipboard. A selection belongs to the
//! client that owns it, and reading it needs an active data offer, so history
//! requires something long-lived holding one. `wl-paste --watch` does exactly
//! that, and [`watch`] wraps it: every new selection is appended to the log
//! the clipboard provider reads. That watcher used to be its own systemd
//! service; [`serve`] now runs it as one of three threads inside the same
//! process that hosts the launcher and the D-Bus interface — see `serve`'s
//! own docs for why the split falls where it does.
//!
//! Run as a systemd user service by `nix/home/beamenu.nix`.

use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};

use crate::providers::clipboard::{append, compact, Entry, HISTORY_LIMIT};
use crate::{ipc, view, App};

/// Entries appended between compactions.
const COMPACT_INTERVAL: usize = 64;

/// Delay before the clipboard watcher retries after `wl-paste` dies.
const RETRY_DELAY: Duration = Duration::from_secs(3);

/// Longest selection stored. Anything past this is almost certainly a file
/// dump or an image encoded as text, neither of which belongs in a history
/// list that renders one line per entry.
const MAX_ENTRY_BYTES: usize = 64 * 1024;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Decide whether a captured selection is worth storing.
///
/// Blank selections are noise, and oversized ones are not history.
#[must_use]
pub fn should_store(text: &str) -> bool {
    !text.trim().is_empty() && text.len() <= MAX_ENTRY_BYTES
}

/// Watch the clipboard until the watcher dies, appending to `log`.
///
/// `wl-paste --watch` runs a command per selection. Rather than spawning a
/// shell each time, this asks it to run `cat`, which writes the selection to
/// the pipe that this process reads: one long-lived child, no per-copy fork.
/// The `\0` record separator is what keeps multi-line selections intact.
///
/// # Errors
/// Fails when `wl-paste` is missing, its pipe breaks, or the log is unwritable.
pub fn watch(log: &Path) -> Result<()> {
    let mut child = Command::new("wl-paste")
        .args(["--type", "text", "--watch", "sh", "-c", "cat; printf '\\0'"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("wl-paste is not available")?;

    let stdout = child.stdout.take().context("wl-paste stdout not piped")?;
    let mut reader = BufReader::new(stdout);
    let mut appended = 0usize;

    loop {
        let mut buffer = Vec::new();
        let read = reader
            .read_until(0, &mut buffer)
            .context("failed reading from wl-paste")?;
        if read == 0 {
            break;
        }
        if buffer.last() == Some(&0) {
            buffer.pop();
        }

        let Ok(text) = String::from_utf8(buffer) else {
            // A non-UTF-8 selection is an image or some binary payload; the
            // history list has nothing useful to show for it.
            continue;
        };
        if !should_store(&text) {
            continue;
        }

        append(
            log,
            &Entry {
                at: now_secs(),
                text,
            },
        )?;

        appended += 1;
        if appended >= COMPACT_INTERVAL {
            appended = 0;
            // The log only ever grows on append, so trim it back to the
            // window the provider actually reads.
            let _ = compact(log);
        }
    }

    let _ = child.wait();
    Ok(())
}

/// Path of the clipboard log inside `state_dir`.
#[must_use]
pub fn log_path(state_dir: &Path) -> std::path::PathBuf {
    state_dir.join("clipboard.jsonl")
}

/// Entries the provider will show. Re-exported so the service and the reader
/// cannot disagree about the window.
#[must_use]
pub const fn history_limit() -> usize {
    HISTORY_LIMIT
}

/// Copy what the bus thread reports about the launcher out of `app`.
///
/// Called after every refresh rather than read on demand, because the `App`
/// belongs to the UI thread and a property read arrives on zbus's.
pub fn publish(app: &App, shared: &ipc::Shared) {
    shared
        .apps
        .store(app.ctx.apps.entries().len(), Ordering::SeqCst);
    shared
        .providers
        .store(app.providers.len(), Ordering::SeqCst);
    if let Ok(mut terminal) = shared.terminal.write() {
        terminal.clone_from(&app.ctx.config.terminal);
    }
}

/// Run the resident daemon: bus name, clipboard watcher, and the UI.
///
/// Three threads, and which one is which is forced by the C library. The UI
/// must run on the thread that first touched bemenu, because its renderer
/// keeps the Wayland connection in unsynchronised globals (see
/// [`crate::view::Menu`]) — so the UI keeps the main thread, and zbus's object
/// server and the clipboard watcher, which both only block on reads, get
/// threads of their own.
///
/// # Errors
/// Fails when the session bus is unreachable or when the well-known name is
/// already owned, which means another daemon is running.
pub fn serve() -> Result<()> {
    let state = crate::config::state_dir();
    std::fs::create_dir_all(&state)?;

    // The watcher outlives any single selection, and losing it must not take
    // the launcher down with it: wl-paste dying (a compositor restart, say)
    // costs clipboard history until the next retry, not the daemon.
    //
    // Read straight from disk rather than from the App below, because this
    // decides whether a thread exists at all: nothing later can grow one, and
    // `nix/home/beamenu.nix` puts config.json in the unit's restart triggers
    // for exactly that reason.
    if crate::config::Config::load(&crate::config::config_dir().join("config.json"))
        .clipboard_history
    {
        let log = log_path(&state);
        std::thread::spawn(move || loop {
            if let Err(err) = watch(&log) {
                eprintln!("beamenu: clipboard watcher stopped: {err}");
            }
            std::thread::sleep(RETRY_DELAY);
        });
    }

    let shared = Arc::new(ipc::Shared::new());
    let (tx, rx) = std::sync::mpsc::channel::<ipc::Signal>();

    // Held for the process's lifetime: dropping the connection releases the
    // well-known name, and systemd's Type=dbus readiness is that name.
    let _connection = zbus::blocking::connection::Builder::session()
        .context("no session bus")?
        .name(ipc::BUS_NAME)?
        .serve_at(ipc::OBJECT_PATH, ipc::Beamenu::new(tx, Arc::clone(&shared)))?
        .build()
        .context("another beamenu daemon already owns the name")?;

    let mut app = App::new();
    publish(&app, &shared);

    for signal in rx {
        match signal {
            ipc::Signal::Show => {
                shared.visible.store(true, Ordering::SeqCst);
                app.refresh();
                publish(&app, &shared);

                // Two failures, two answers. A panel that will not open means
                // the display this process attached to is gone, and every
                // later show would fail identically — so exit and let systemd
                // restart us onto a live one, with the client's in-process
                // fallback covering the gap. An action that failed is one
                // missing `wl-copy`, and killing the launcher over it would
                // be absurd.
                let menu = view::Menu::new(&app.ctx.config)
                    .context("cannot open the launcher panel; exiting so systemd restarts us")?;
                let outcome = crate::run_with(menu, &mut app);
                shared.visible.store(false, Ordering::SeqCst);
                if let Err(err) = outcome {
                    eprintln!("beamenu: action failed: {err}");
                }
            }
            ipc::Signal::Reload => {
                app.refresh();
                publish(&app, &shared);
            }
        }
    }

    Ok(())
}
