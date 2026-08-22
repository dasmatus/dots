//! Spawns a command's `exec` child and pipes its stdio to and from the main
//! thread.
//!
//! `ui: "log"` and `ui: "rpc"` both spawn identically; they differ only in
//! how `main.rs` interprets [`WorkerLine::Stdout`] — raw text run through
//! `beamenu_canvas::ansi`, or newline-delimited JSON-RPC run through
//! `beamenu_canvas::rpc`/`dispatch`.
//!
//! No GTK types here: reader threads hand lines to the main thread over a
//! plain [`std::sync::mpsc`] channel, which `main.rs` drains from a
//! `glib::source::timeout_add_local` tick (the `glib::MainContext::channel`
//! convenience API this would otherwise use was removed upstream).

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;

/// `SIGKILL` — the only signal `Worker::kill` sends. The task brief calls
/// for killing an unresponsive child outright after a shutdown grace
/// period, not a graceful `SIGTERM` escalation.
const SIGKILL: i32 = 9;

extern "C" {
    #[link_name = "kill"]
    fn kill_raw(pid: i32, sig: i32) -> i32;
}

/// One event a background thread handed back to the main thread.
#[derive(Debug)]
pub enum WorkerLine {
    Stdout(String),
    Stderr(String),
    Exited(std::io::Result<ExitStatus>),
}

/// A spawned child plus the channel its reader threads feed.
///
/// The `Child` itself lives entirely inside the reaper thread (its `wait()`
/// blocks for the process's whole lifetime), so `Worker` cannot hold a
/// `&mut Child` to call the standard library's own `Child::kill`. It keeps
/// the pid instead and signals by pid directly — see `kill` below.
pub struct Worker {
    stdin: Option<ChildStdin>,
    pub lines: Receiver<WorkerLine>,
    pid: u32,
    exited: Arc<AtomicBool>,
}

impl Worker {
    /// Spawn `argv[0]` with the rest as arguments.
    ///
    /// # Errors
    /// Fails when `argv` is empty or the executable can't be spawned.
    pub fn spawn(argv: &[String]) -> std::io::Result<Self> {
        let (exe, args) = argv.split_first().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "empty exec argv")
        })?;

        let mut child: Child = Command::new(exe)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let pid = child.id();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("stdout was piped");
        let stderr = child.stderr.take().expect("stderr was piped");

        let (tx, rx) = mpsc::channel();

        spawn_line_reader(stdout, tx.clone(), WorkerLine::Stdout);
        spawn_line_reader(stderr, tx.clone(), WorkerLine::Stderr);

        let exited = Arc::new(AtomicBool::new(false));
        let exited_for_reaper = Arc::clone(&exited);
        std::thread::spawn(move || {
            let status = child.wait();
            // Ordered before the channel send so a `kill` racing the
            // reaper never signals a pid the reaper already knows is gone.
            exited_for_reaper.store(true, Ordering::SeqCst);
            let _ = tx.send(WorkerLine::Exited(status));
        });

        Ok(Self {
            stdin,
            lines: rx,
            pid,
            exited,
        })
    }

    /// Write one JSON-RPC message, newline-terminated, to the worker's
    /// stdin — the framing `crate::rpc::parse_incoming` expects on the way
    /// back.
    ///
    /// # Errors
    /// Fails when stdin is already closed, or the write fails.
    pub fn send(&mut self, message: &serde_json::Value) -> std::io::Result<()> {
        let stdin = self.stdin.as_mut().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::BrokenPipe, "worker stdin is closed")
        })?;
        let mut line = serde_json::to_string(message)
            .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))?;
        line.push('\n');
        stdin.write_all(line.as_bytes())
    }

    /// `SIGKILL` the child by pid, skipped if the reaper thread has already
    /// observed it exit.
    ///
    /// Sending a signal to a pid Rust's `Child` handle isn't exclusively
    /// held for is the standard escape hatch when another thread owns that
    /// handle (here, blocked in `wait()`) — the `exited` check closes
    /// almost all of the window where the pid could already have been
    /// recycled by the kernel for an unrelated process, though not the
    /// handful of instructions between that check and the signal itself.
    /// Acceptable for a plugin sidecar killing its own direct child on
    /// window close, not a substitute for a real subreaper.
    pub fn kill(&self) {
        if self.exited.load(Ordering::SeqCst) {
            return;
        }
        // SAFETY: `kill(2)` with a pid_t and a signal number has no
        // memory-safety preconditions of its own; the worst case is ESRCH
        // if the pid has already exited, which the check above screens for
        // in all but the unavoidable check-then-act race described above.
        // `try_from` rather than `as`: real pids never exceed i32::MAX (the
        // kernel's own pid_max ceiling is far below it), so this only ever
        // falls back to a guaranteed-ESRCH sentinel, never wraps a real pid
        // negative.
        let pid = i32::try_from(self.pid).unwrap_or(i32::MAX);
        unsafe {
            kill_raw(pid, SIGKILL);
        }
    }
}

fn spawn_line_reader<R>(stream: R, tx: mpsc::Sender<WorkerLine>, wrap: fn(String) -> WorkerLine)
where
    R: std::io::Read + Send + 'static,
{
    std::thread::spawn(move || {
        let reader = BufReader::new(stream);
        for line in reader.lines() {
            let Ok(text) = line else { break };
            if tx.send(wrap(text)).is_err() {
                break;
            }
        }
    });
}
