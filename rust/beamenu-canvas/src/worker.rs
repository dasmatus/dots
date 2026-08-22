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
use std::sync::mpsc::{self, Receiver};

/// One event a background thread handed back to the main thread.
#[derive(Debug)]
pub enum WorkerLine {
    Stdout(String),
    Stderr(String),
    Exited(std::io::Result<ExitStatus>),
}

/// A spawned child plus the channel its reader threads feed.
pub struct Worker {
    stdin: Option<ChildStdin>,
    pub lines: Receiver<WorkerLine>,
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

        let stdin = child.stdin.take();
        let stdout = child.stdout.take().expect("stdout was piped");
        let stderr = child.stderr.take().expect("stderr was piped");

        let (tx, rx) = mpsc::channel();

        spawn_line_reader(stdout, tx.clone(), WorkerLine::Stdout);
        spawn_line_reader(stderr, tx.clone(), WorkerLine::Stderr);

        std::thread::spawn(move || {
            let status = child.wait();
            let _ = tx.send(WorkerLine::Exited(status));
        });

        Ok(Self { stdin, lines: rx })
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
