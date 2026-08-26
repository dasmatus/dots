//! `beamenu-canvas --preview`: the launcher's resident preview pane.
//!
//! One process for the whole life of the launcher, reading protocol lines on
//! stdin and drawing whichever row the highlight is on. This is the half of
//! the split the launcher refuses to do itself: opening the file, deciding
//! what it is, and laying it out. The pure part of that lives in
//! [`beamenu_canvas::preview`]; what is left here is the IO and the GTK.
//!
//! Two things keep a preview from costing what it looks like it should.
//!
//! Every render is debounced. Holding an arrow key down walks the highlight
//! through a list, and rendering each row it passes would read a file per row
//! and, for a plugin view, spawn a process per row. A row has to be rested on
//! before it is drawn. Plugin views wait longer than files, because starting a
//! process is the more expensive mistake.
//!
//! The pane is never destroyed, only concealed. Its surface is mapped once and
//! hidden between shows, so the second preview of a session costs a render
//! rather than a WebKit startup.

use std::cell::{Cell, RefCell};
use std::io::{BufRead, Read};
use std::path::Path;
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, UNIX_EPOCH};

use gtk4::glib;
use gtk4::prelude::*;

use beamenu_canvas::manifest::{substitute_query, Manifest};
use beamenu_canvas::preview::{
    self, Entry, Geometry, Message, Preview, MAX_IMAGE_BYTES, MAX_TEXT_BYTES,
};
use beamenu_canvas::theme::CanvasTheme;
use beamenu_canvas::{markdown, shell};

use crate::window::Canvas;
use crate::worker::{Worker, WorkerLine};

/// How long a row must be rested on before a file preview is drawn.
const DEBOUNCE_FILE: Duration = Duration::from_millis(120);

/// How long before a plugin view is drawn. Longer, because drawing one starts
/// a process, and a process started for a row already left behind is worse
/// than a file read wasted on one.
const DEBOUNCE_COMMAND: Duration = Duration::from_millis(400);

/// How often the GTK loop drains the stdin reader's channel.
const TICK: Duration = Duration::from_millis(16);

/// Run the pane until the launcher closes stdin or sends `quit`.
pub fn run(theme: CanvasTheme) -> ExitCode {
    let app = gtk4::Application::builder()
        .application_id("dev.dots.beamenu-canvas")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    // The reader is a plain thread over a blocking stdin, handing lines to the
    // GTK loop over a channel, for the same reason `worker.rs` does it: the
    // GLib main context has no business blocking on a pipe, and the
    // convenience API that used to bridge the two was removed upstream.
    let inbox = RefCell::new(Some(spawn_reader()));

    app.connect_activate(move |app| {
        let Some(inbox) = inbox.borrow_mut().take() else {
            return;
        };
        // The pane starts with nothing to show and its surface unmapped, and
        // GApplication ends its run once nothing is keeping it alive. Without
        // this the process would exit before the launcher's first message
        // arrived, which looks exactly like a pane that never worked. The
        // guard is dropped by `drive`'s source when it stops, which is the
        // one place that decides the pane is finished.
        let hold = app.hold();
        let pane = Rc::new(Pane::new(Canvas::build_preview(app, &theme)));
        drive(app, &pane, inbox, hold);
    });

    let no_args: [&str; 0] = [];
    let _ = app.run_with_args(&no_args);
    ExitCode::SUCCESS
}

/// The pane's mutable state: where its column is, what it is about to draw,
/// and the plugin worker it may have started for it.
struct Pane {
    canvas: Canvas,
    geometry: Cell<Geometry>,
    /// Bumped by every `show`. A debounce timer that fires holding a stale
    /// generation is a row the highlight has already moved off.
    generation: Cell<u64>,
    pending: RefCell<Option<Message>>,
    /// The worker behind a `command` preview, killed whenever the pane moves
    /// on. Only one can be running: the pane draws one row at a time.
    worker: RefCell<Option<Worker>>,
    /// Output accumulated from that worker, capped at [`MAX_TEXT_BYTES`].
    output: RefCell<String>,
}

impl Pane {
    fn new(canvas: Canvas) -> Self {
        Self {
            canvas,
            geometry: Cell::new(Geometry::default()),
            generation: Cell::new(0),
            pending: RefCell::new(None),
            worker: RefCell::new(None),
            output: RefCell::new(String::new()),
        }
    }

    /// Drop whatever the pane was drawing, stopping any worker behind it.
    fn abandon(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        self.pending.borrow_mut().take();
        if let Some(worker) = self.worker.borrow_mut().take() {
            worker.kill();
        }
        self.output.borrow_mut().clear();
    }
}

/// Wire the channel into the GTK loop and start draining it.
///
/// `hold` is captured by value rather than dropped explicitly: the closure has
/// to be `FnMut`, so a `drop` inside it would only be valid for one call. GLib
/// discards the closure once it returns `Break`, and that is what releases the
/// application.
fn drive(
    app: &gtk4::Application,
    pane: &Rc<Pane>,
    inbox: Receiver<Message>,
    hold: gtk4::gio::ApplicationHoldGuard,
) {
    let app = app.clone();
    let pane = pane.clone();
    glib::source::timeout_add_local(TICK, move || {
        let _ = &hold; // held, not used
        while let Ok(message) = inbox.try_recv() {
            if handle(&pane, &message) == Flow::Quit {
                app.quit();
                return glib::ControlFlow::Break;
            }
        }
        pump_worker(&pane);
        glib::ControlFlow::Continue
    });
}

#[derive(PartialEq, Eq)]
enum Flow {
    Continue,
    Quit,
}

fn handle(pane: &Rc<Pane>, message: &Message) -> Flow {
    match message {
        Message::Metrics {
            width,
            height,
            list_width,
            content_y,
        } => {
            let geometry = Geometry {
                width: *width,
                height: *height,
                list_width: *list_width,
                content_y: *content_y,
            };
            pane.geometry.set(geometry);
            pane.canvas.place(geometry);
            Flow::Continue
        }
        Message::Show { preview, .. } => {
            pane.abandon();
            *pane.pending.borrow_mut() = Some(message.clone());

            let delay = match preview {
                Preview::Command { .. } => DEBOUNCE_COMMAND,
                Preview::File { .. } | Preview::Markdown { .. } => DEBOUNCE_FILE,
            };
            let generation = pane.generation.get();
            let pane = pane.clone();
            glib::source::timeout_add_local_once(delay, move || {
                if pane.generation.get() != generation {
                    return;
                }
                let Some(message) = pane.pending.borrow_mut().take() else {
                    return;
                };
                draw(&pane, &message);
            });
            Flow::Continue
        }
        Message::Hide => {
            pane.abandon();
            pane.canvas.conceal();
            Flow::Continue
        }
        Message::Quit => {
            pane.abandon();
            Flow::Quit
        }
    }
}

/// Render one `show` into the pane, now that it has survived the debounce.
fn draw(pane: &Rc<Pane>, message: &Message) {
    let Message::Show {
        title,
        subtitle,
        preview,
        metadata,
        ..
    } = message
    else {
        return;
    };

    let (body, extra) = match preview {
        Preview::File { path } => render_file(path),
        Preview::Markdown { body } => (markdown::render(body), Vec::new()),
        Preview::Command {
            manifest,
            command,
            query,
        } => (
            start_command(pane, manifest, command, query.as_str()),
            Vec::new(),
        ),
    };

    // The launcher's own rows come first: they are what it already knew about
    // the thing, and they name it. What the pane worked out from the bytes
    // follows.
    let mut rows = metadata.clone();
    rows.extend(extra);

    show(pane, title, subtitle.as_deref(), &body, &rows);
}

fn show(
    pane: &Rc<Pane>,
    title: &str,
    subtitle: Option<&str>,
    body: &str,
    rows: &[(String, String)],
) {
    // Mapped first, then placed, then filled. `Canvas::place` narrows the
    // surface's input region, and a surface that has not been mapped has no
    // input region to narrow: doing this the other way round leaves the very
    // first preview swallowing every click over the result list. Revealing
    // first costs nothing to look at, because the page keeps its column
    // hidden until `show` puts something in it.
    pane.canvas.reveal();
    pane.canvas.place(pane.geometry.get());
    pane.canvas.eval(&shell::call_show_preview(
        title,
        subtitle,
        body,
        &preview::metadata_html(rows),
    ));
}

/// Read whatever is at `path` and turn it into the pane's body, plus the
/// metadata rows only a stat could produce.
fn render_file(path: &Path) -> (String, Vec<(String, String)>) {
    let Ok(meta) = std::fs::metadata(path) else {
        return (
            preview::card_html("This file could not be read."),
            Vec::new(),
        );
    };

    let mut rows = Vec::new();
    if let Ok(modified) = meta.modified() {
        if let Ok(since) = modified.duration_since(UNIX_EPOCH) {
            let seconds = i64::try_from(since.as_secs()).unwrap_or(i64::MAX);
            rows.push((
                "Modified".to_string(),
                preview::format_timestamp(seconds.saturating_add(local_offset_seconds())),
            ));
        }
    }

    if meta.is_dir() {
        let (body, count, kind) = render_directory(path);
        rows.insert(0, ("Kind".to_string(), kind.to_string()));
        rows.insert(1, ("Items".to_string(), count.to_string()));
        return (body, rows);
    }

    rows.insert(0, ("Kind".to_string(), describe_kind(path)));
    rows.insert(1, ("Size".to_string(), preview::format_bytes(meta.len())));

    if let Some(mime) = preview::image_mime(path) {
        if meta.len() <= MAX_IMAGE_BYTES {
            return match std::fs::read(path) {
                Ok(bytes) => (preview::image_html(mime, &bytes), rows),
                Err(_) => (preview::card_html("This image could not be read."), rows),
            };
        }
        return (preview::card_html("Too large to preview inline."), rows);
    }

    // A page renders as the page. Showing markup as source in something that
    // is literally a browser engine would be the one thing this pane has no
    // excuse for. `document_html` is what keeps that from also meaning the
    // page gets to run with the pane's privileges.
    if preview::is_html(path) {
        return match read_prefix(path) {
            Some(bytes) => (preview::document_html(preview::text_prefix(&bytes)), rows),
            None => (preview::card_html("This page could not be read."), rows),
        };
    }

    match read_prefix(path) {
        Some(bytes) if preview::looks_like_text(&bytes) => {
            let truncated = bytes.len() > MAX_TEXT_BYTES;
            let text = preview::text_prefix(&bytes[..bytes.len().min(MAX_TEXT_BYTES)]);
            (preview::text_html(text, truncated), rows)
        }
        Some(_) => (preview::card_html("No preview for this file type."), rows),
        None => (preview::card_html("This file could not be read."), rows),
    }
}

/// Read at most one byte more than [`MAX_TEXT_BYTES`], so the caller can tell
/// a file that ended from one that was cut.
fn read_prefix(path: &Path) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    let mut buffer = Vec::new();
    file.take(MAX_TEXT_BYTES as u64 + 1)
        .read_to_end(&mut buffer)
        .ok()?;
    Some(buffer)
}

/// Preview a directory: its index page if it has one, otherwise its contents.
///
/// Returns the body, how many entries the directory holds, and what to call
/// it in the metadata strip.
fn render_directory(path: &Path) -> (String, usize, &'static str) {
    let Ok(read) = std::fs::read_dir(path) else {
        return (
            preview::card_html("This folder could not be read."),
            0,
            "Folder",
        );
    };

    let entries: Vec<Entry> = read
        .flatten()
        .map(|entry| Entry {
            name: entry.file_name().to_string_lossy().into_owned(),
            // `file_type` avoids a stat per entry; a symlink whose target is
            // gone answers "not a directory", which is the right answer for a
            // listing anyway.
            is_dir: entry.file_type().is_ok_and(|kind| kind.is_dir()),
        })
        .collect();

    // A directory with an index page is a site, and a site's preview is the
    // site. Its own listing is twelve filenames that say nothing about it.
    if let Some(index) = preview::web_app_entry(&entries) {
        if let Some(bytes) = read_prefix(&path.join(index)) {
            return (
                preview::document_html(preview::text_prefix(&bytes)),
                entries.len(),
                "Web app",
            );
        }
    }

    let count = entries.len();
    let (arranged, total) = preview::arrange_listing(entries);
    (preview::listing_html(&arranged, total), count, "Folder")
}

/// A file's kind, as its extension names it.
fn describe_kind(path: &Path) -> String {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map_or_else(
            || "File".to_string(),
            |extension| format!("{} file", extension.to_uppercase()),
        )
}

/// Start a plugin command's view in the pane, and return the placeholder to
/// show until it has said anything.
fn start_command(pane: &Rc<Pane>, manifest: &Path, command: &str, query: &str) -> String {
    let Ok(loaded) = Manifest::load(manifest) else {
        return preview::card_html("This plugin's manifest could not be read.");
    };
    let Ok(command) = loaded.command(command) else {
        return preview::card_html("This plugin has no such command.");
    };

    let argv = substitute_query(&command.exec, Some(query));
    match Worker::spawn(&argv) {
        Ok(worker) => {
            *pane.worker.borrow_mut() = Some(worker);
            preview::card_html("Running…")
        }
        Err(_) => preview::card_html("This plugin's command could not be started."),
    }
}

/// Drain a running command's output into the pane.
///
/// The whole body is re-rendered per chunk rather than appended to. A preview
/// is a glance at a command that prints a handful of lines, so the simple
/// thing costs nothing measurable here, and it keeps the page's contract down
/// to one call. A command that turns out to print megabytes stops at
/// [`MAX_TEXT_BYTES`] and says so.
fn pump_worker(pane: &Rc<Pane>) {
    let mut lines = Vec::new();
    let mut finished = false;
    {
        let worker = pane.worker.borrow();
        let Some(worker) = worker.as_ref() else {
            return;
        };
        while let Ok(line) = worker.lines.try_recv() {
            match line {
                WorkerLine::Stdout(text) | WorkerLine::Stderr(text) => lines.push(text),
                WorkerLine::Exited(_) => finished = true,
            }
        }
    }

    if lines.is_empty() && !finished {
        return;
    }

    let truncated = {
        let mut output = pane.output.borrow_mut();
        for line in lines {
            if output.len() >= MAX_TEXT_BYTES {
                break;
            }
            output.push_str(&line);
            output.push('\n');
        }
        output.len() >= MAX_TEXT_BYTES
    };

    let body = preview::text_html(&pane.output.borrow(), truncated);
    pane.canvas.eval(&shell::call_show_preview_body(&body));

    if finished {
        pane.worker.borrow_mut().take();
    }
}

/// `struct tm`, sized so `localtime_r` cannot write past the end of it.
///
/// Only the first nine `int`s are read, and those nine are POSIX: seconds,
/// minutes, hours, day, month, year, weekday, yearday, DST flag, in that
/// order. glibc appends `tm_gmtoff` and `tm_zone` after them, and BSD libcs
/// append the same two; naming either would be claiming a layout this code
/// does not depend on, so the tail is reserved as opaque storage instead,
/// over-sized and 8-aligned so the pointer members land inside it whatever
/// the C library thinks they are.
#[repr(C, align(8))]
struct CTm {
    fields: [std::ffi::c_int; 9],
    _tail: [u64; 4],
}

extern "C" {
    fn localtime_r(time: *const i64, result: *mut CTm) -> *mut CTm;
}

/// Seconds to add to a UTC timestamp to get local time, resolved once.
///
/// `crate::preview::format_timestamp` deliberately knows nothing about
/// timezones, so the shift happens here. Resolved once per process rather
/// than per preview: the answer costs a `/etc/localtime` read inside the C
/// library, and a launcher session is not long enough for a DST transition
/// to matter.
///
/// A file's timestamp is what the desktop's own clock would say about it. UTC
/// would be defensible and still wrong by an hour or two next to a panel
/// showing local time, which is exactly where this text appears.
fn local_offset_seconds() -> i64 {
    static OFFSET: std::sync::OnceLock<i64> = std::sync::OnceLock::new();

    *OFFSET.get_or_init(|| {
        // A fixed instant, not "now": the offset is read once and reused, so
        // reading it for a moment that has already passed is no worse than
        // reading it for this one, and a constant keeps the call pure.
        let probe: i64 = 1_000_000_000;
        let mut tm = CTm {
            fields: [0; 9],
            _tail: [0; 4],
        };

        // SAFETY: `probe` is a live i64 for the call, and `tm` is a live,
        // over-sized, correctly aligned `struct tm` the C library fills in.
        // A NULL return means the conversion failed, which is handled below
        // rather than dereferenced.
        if unsafe { localtime_r(&raw const probe, &raw mut tm) }.is_null() {
            return 0;
        }

        // Rebuild the UTC instant the broken-down local time describes; the
        // difference from the probe is the offset. This avoids reading
        // `tm_gmtoff`, which is the one field whose position is not POSIX.
        let [second, minute, hour, day, month, year, ..] = tm.fields;
        let local = days_from_civil(i64::from(year) + 1900, i64::from(month) + 1, i64::from(day))
            * 86_400
            + i64::from(hour) * 3600
            + i64::from(minute) * 60
            + i64::from(second);
        local - probe
    })
}

/// Days since the Unix epoch for a civil date. Howard Hinnant's algorithm,
/// the forward direction of the one `crate::preview::format_timestamp` runs
/// backwards.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Read protocol lines off stdin on a thread of their own.
///
/// EOF is the launcher exiting without saying so, which is what happens when
/// it is killed rather than closed. Synthesising a `quit` there is what stops
/// the pane outliving the thing it belongs to.
fn spawn_reader() -> Receiver<Message> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            let Some(message) = preview::parse_line(&line) else {
                continue;
            };
            let quit = message == Message::Quit;
            if tx.send(message).is_err() || quit {
                return;
            }
        }
        let _ = tx.send(Message::Quit);
    });
    rx
}
