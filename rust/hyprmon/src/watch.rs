//! The event watcher: a long-running daemon mode (`hyprmon watch`) that
//! applies once on startup, then subscribes to Hyprland's IPC socket2 and
//! re-applies whenever a monitor is added/removed or the config is reloaded.
//!
//! Socket2 is a line-oriented event stream: each event is `NAME>>args\n`
//! (e.g. `monitoradded>>DP-1\n`). We only care about the small set of events
//! that change the monitor topology; everything else is ignored. Re-applies
//! are debounced with a short settle window so a burst of events (e.g.
//! unplugging a dock fires `monitorremoved` for several outputs at once)
//! collapses into one `hyprctl keyword` pass.
//!
//! Architecture: a reader thread drains the (blocking) [`EventStream`] into an
//! mpsc channel; the main loop `recv_timeout`s on that channel so it can wake
//! either on the debounce deadline OR a freshly-arrived event, whichever is
//! first. A trigger event (re)sets the deadline; the deadline firing triggers
//! one apply. This is the only way to collapse a burst with a blocking stream
//! — sleeping and reading can't happen at the same time on one thread.
//!
//! The stream read is behind an [`EventStream`] trait so the loop is
//! unit-testable without a live compositor: a synthetic backend feeds events
//! through the same mpsc channel the reader thread uses.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use crate::rules::Rules;
use crate::spec::MonitorSpec;

/// The Hyprland events that should trigger a re-apply. Everything else on
/// socket2 is ignored.
const TRIGGER_EVENTS: &[&str] = &["monitoradded", "monitorremoved", "configreloaded"];

/// Debounce window: collapse a burst of events into one re-apply. 300 ms is
/// enough for a dock plug/unplug to finish firing all its `monitorremoved`
/// events without making the desktop lag perceptibly on a single hotplug.
const DEBOUNCE: Duration = Duration::from_millis(300);

/// Indirection over Hyprland's socket2 so the watch loop is testable without
/// a live compositor. A live impl connects to the real socket; a test impl
/// feeds events through a channel.
pub trait EventStream: Send + 'static {
    /// Block until the next event line is available, then return it. Returns
    /// `None` when the stream is closed (compositor gone) so the reader
    /// thread exits cleanly and the watch loop's channel drains to EOF.
    fn next_event(&mut self) -> Option<String>;
}

/// Live socket2 backend. Connects to
/// `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock` and
/// reads line-by-line. Each [`next_event`](Self::next_event) call blocks on
/// one `read_line`.
pub struct Socket2Stream {
    reader: BufReader<UnixStream>,
}

impl Socket2Stream {
    /// Open the socket. Fails if `HYPRLAND_INSTANCE_SIGNATURE` is unset or
    /// the socket isn't reachable (e.g. not running under Hyprland).
    pub fn open() -> Result<Self, String> {
        let path = socket2_path()?;
        let sock =
            UnixStream::connect(&path).map_err(|e| format!("connect {}: {e}", path.display()))?;
        Ok(Self {
            reader: BufReader::new(sock),
        })
    }
}

impl EventStream for Socket2Stream {
    fn next_event(&mut self) -> Option<String> {
        let mut buf = String::new();
        match self.reader.read_line(&mut buf) {
            Ok(0) => None, // EOF — compositor closed the socket
            Ok(_) => Some(buf.trim_end().to_string()),
            Err(_) => None,
        }
    }
}

fn socket2_path() -> Result<PathBuf, String> {
    let his = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .map_err(|_| "HYPRLAND_INSTANCE_SIGNATURE not set".to_string())?;
    let xdg =
        std::env::var("XDG_RUNTIME_DIR").map_err(|_| "XDG_RUNTIME_DIR not set".to_string())?;
    Ok(PathBuf::from(xdg)
        .join("hypr")
        .join(his)
        .join(".socket2.sock"))
}

/// Apply callback indirection so the watch loop is testable without a live
/// `hyprctl`: the live impl shells out via [`crate::runner::apply`]; a test
/// impl records the specs it was handed.
pub trait Applier {
    fn apply(&self, rules: &Rules) -> Result<Vec<MonitorSpec>, String>;
}

/// Watch loop: spawn a reader thread for `stream`, apply once, then
/// `recv_timeout` on the reader's channel. A trigger event (re)sets the
/// debounce deadline; the deadline firing triggers one apply. Exits when the
/// reader thread ends (stream EOF) and the channel drains.
///
/// Generic over both the event stream and the applier so the loop has no
/// live dependencies. `Send + 'static` on [`EventStream`] is the one
/// constraint — the stream moves into the reader thread.
pub fn watch(
    stream: impl EventStream,
    applier: &impl Applier,
    rules: &Rules,
) -> Result<(), String> {
    let (tx, rx) = mpsc::channel::<Option<String>>();
    // Reader thread: forward each event (or None on EOF) to the channel.
    // The `Option` wrapper lets the loop distinguish "stream closed" from
    // "no event yet" — on None the loop stops waiting and exits.
    let mut reader = stream;
    thread::spawn(move || loop {
        let ev = reader.next_event();
        let _ = tx.send(ev.clone());
        if ev.is_none() {
            break;
        }
    });

    // Initial apply — don't wait for an event, the service starts after
    // Hyprland is already up so the topology is live now.
    let _ = applier.apply(rules);
    let mut deadline: Option<Instant> = None;
    loop {
        let timeout = deadline.map_or(Duration::MAX, |dl| {
            dl.saturating_duration_since(Instant::now())
        });
        match rx.recv_timeout(timeout) {
            Ok(Some(line)) => {
                if is_trigger(&line) {
                    // (Re)arm: a fresh trigger resets the window so a burst
                    // collapses into one apply once events stop arriving.
                    deadline = Some(Instant::now() + DEBOUNCE);
                }
            }
            Ok(None) => {
                // Stream closed — apply any pending deadline, then exit.
                if deadline.is_some() {
                    let _ = applier.apply(rules);
                }
                return Ok(());
            }
            Err(RecvTimeoutError::Timeout) => {
                // Deadline elapsed with no new triggers → one apply, disarm.
                let _ = applier.apply(rules);
                deadline = None;
            }
            Err(RecvTimeoutError::Disconnected) => {
                // Reader thread died — apply pending then exit.
                if deadline.is_some() {
                    let _ = applier.apply(rules);
                }
                return Ok(());
            }
        }
    }
}

/// Is `line` one of the trigger events? A socket2 line looks like
/// `monitoradded>>DP-1`; we match the prefix before `>>`.
fn is_trigger(line: &str) -> bool {
    let name = line.split(">>").next().unwrap_or(line);
    TRIGGER_EVENTS.contains(&name)
}

/// Parse a socket2 line into `(event_name, args)`. Kept public for tests even
/// though the watch loop only needs the boolean — handy for asserting which
/// event fired.
#[must_use]
pub fn parse_event(line: &str) -> (&str, &str) {
    let (name, rest) = line.split_once(">>").unwrap_or((line, ""));
    (name, rest)
}

/// No-arg constructor helper for tests that want to assert `is_trigger`
/// against synthetic lines without building a full stream.
#[must_use]
pub fn trigger_counts(lines: &[String]) -> HashMap<String, usize> {
    let mut counts = HashMap::new();
    for l in lines {
        if is_trigger(l) {
            let name = parse_event(l).0.to_string();
            *counts.entry(name).or_insert(0) += 1;
        }
    }
    counts
}
