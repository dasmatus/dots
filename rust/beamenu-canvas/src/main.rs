//! `beamenu-canvas`'s entry point.
//!
//! `beamenu-canvas --manifest <path> --command <id> [--query <string>]`
//! (binding argv contract, task brief): loads the manifest, finds the
//! command, substitutes `{query}` into its `exec` argv, and opens a
//! layer-shell WebKitGTK window that renders the command's output — either
//! streamed log text (`ui: "log"`, the default) or a JSON-RPC-driven
//! component tree (`ui: "rpc"`). Esc closes the window; the process exits
//! when it does.

mod window;
mod worker;

use std::cell::RefCell;
use std::process::ExitCode;
use std::rc::Rc;
use std::time::Duration;

use clap::Parser;
use gtk4::glib;
use gtk4::prelude::*;

use beamenu_canvas::cli::Cli;
use beamenu_canvas::component::Component;
use beamenu_canvas::dispatch::{dispatch_notification, CanvasEvent};
use beamenu_canvas::manifest::{substitute_query, Manifest, Ui};
use beamenu_canvas::{ansi, config, markdown, rpc, shell};

use window::Canvas;
use worker::{Worker, WorkerLine};

/// The manifest or command id named on argv didn't resolve to anything
/// runnable.
const EXIT_USAGE: u8 = 2;

/// How long the child gets, after `shutdown` is sent (`ui: "rpc"`) or
/// immediately (`ui: "log"`), to exit on its own before `Worker::kill`
/// sends it `SIGKILL`. Closing the canvas must never leave a worker or exec
/// child running past this.
const SHUTDOWN_GRACE: Duration = Duration::from_millis(500);

fn main() -> ExitCode {
    let cli = Cli::parse();

    let manifest = match Manifest::load(&cli.manifest) {
        Ok(manifest) => manifest,
        Err(err) => {
            eprintln!("beamenu-canvas: {err}");
            return ExitCode::from(EXIT_USAGE);
        }
    };
    let Ok(command) = manifest.command(&cli.command) else {
        eprintln!(
            "beamenu-canvas: no command '{}' in {}",
            cli.command,
            cli.manifest.display()
        );
        return ExitCode::from(EXIT_USAGE);
    };
    let argv = substitute_query(&command.exec, cli.query.as_deref());
    let ui_mode = command.ui;

    let config = config::Config::load(&config::config_dir().join("config.json"));
    let theme = config.theme.canvas;
    let width_factor = config.width_factor;

    // NON_UNIQUE: without it, `gio::Application` D-Bus-activates whatever
    // process first registered "dev.dots.beamenu-canvas" instead of
    // actually starting a new one — every subsequent `beamenu-canvas`
    // invocation (opening a second plugin view while one is still open)
    // would silently pile another window onto the FIRST process rather
    // than running independently, and closing any one of them would
    // `app.quit()` the shared process out from under all the others. Each
    // invocation of this argv contract is meant to be its own sidecar.
    let app = gtk4::Application::builder()
        .application_id("dev.dots.beamenu-canvas")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(move |app| {
        let canvas = Rc::new(Canvas::build(app, &theme, width_factor));

        let worker = match Worker::spawn(&argv) {
            Ok(worker) => worker,
            Err(err) => {
                render_error(&canvas, &format!("failed to start plugin command: {err}"));
                return;
            }
        };
        let worker = Rc::new(RefCell::new(worker));
        connect_shutdown(app, &canvas, &worker, matches!(ui_mode, Ui::Rpc));

        match ui_mode {
            Ui::Log => {
                canvas.eval(&shell::call_render_log());
                run_log_mode(&canvas, &worker);
            }
            Ui::Rpc => run_rpc_mode(&canvas, &worker),
        }
    });

    // Parse zero args ourselves: GApplication would otherwise try (and
    // fail) to interpret --manifest/--command/--query as its own options,
    // since clap already parsed the real argv above.
    let no_args: [&str; 0] = [];
    let _ = app.run_with_args(&no_args);

    ExitCode::SUCCESS
}

/// Wire the window's `close-request` (which the Esc handler's
/// `window.close()` also funnels through) to a graceful-then-forced worker
/// shutdown: send `shutdown` first for `ui: "rpc"`, then `SIGKILL` the
/// child if it hasn't exited within `SHUTDOWN_GRACE`.
///
/// `app.hold()` keeps the GLib main loop (and so the process) alive for
/// that grace window even though the window itself is hidden immediately
/// for an instant-feeling close; the grace timer's `app.quit()` is what
/// actually ends it. `hold()` returns an `ApplicationHoldGuard` whose
/// `Drop` is the actual release — it has to be kept alive (here, in a
/// shared `Rc` cloned into the one-shot timer below) rather than discarded
/// as a bare statement, or the hold ends the instant it's taken.
fn connect_shutdown(
    app: &gtk4::Application,
    canvas: &Rc<Canvas>,
    worker: &Rc<RefCell<Worker>>,
    is_rpc: bool,
) {
    let hold_guard = Rc::new(app.hold());
    let app = app.clone();
    let worker = worker.clone();
    canvas.window.connect_close_request(move |window| {
        window.set_visible(false);
        if is_rpc {
            let _ = worker.borrow_mut().send(&rpc::shutdown_notification());
        }
        let app = app.clone();
        let worker = worker.clone();
        // `timeout_add_local` needs `FnMut`, not `FnOnce`, so the guard
        // can't be explicitly `drop`-ed inside it (that would only be valid
        // for a single call) — it's captured by value instead and released
        // when GLib discards this closure after it returns `Break`.
        let hold_guard = hold_guard.clone();
        glib::source::timeout_add_local(SHUTDOWN_GRACE, move || {
            let _ = &hold_guard; // held, not used — keeps the app alive until here
            worker.borrow().kill();
            app.quit();
            glib::ControlFlow::Break
        });
        glib::Propagation::Stop
    });
}

/// Poll the worker's channel for `ui: "log"`: raw stdout/stderr text run
/// through basic ANSI handling, exit status shown once the child exits.
fn run_log_mode(canvas: &Rc<Canvas>, worker: &Rc<RefCell<Worker>>) {
    let canvas = canvas.clone();
    let worker = worker.clone();
    glib::source::timeout_add_local(Duration::from_millis(16), move || {
        let mut exited = false;
        while let Ok(line) = worker.borrow().lines.try_recv() {
            match line {
                WorkerLine::Stdout(text) => {
                    let html = ansi::to_html(&ansi::parse(&text));
                    canvas.eval(&shell::call_append_log(&format!("{html}\n")));
                }
                WorkerLine::Stderr(text) => {
                    let html = ansi::to_html(&ansi::parse(&text));
                    canvas.eval(&shell::call_append_stderr(&format!("{html}\n")));
                }
                WorkerLine::Exited(status) => {
                    let summary = status.map_or_else(
                        |err| format!("wait failed: {err}"),
                        |status| format!("exited: {status}"),
                    );
                    canvas.eval(&shell::call_show_exit(&summary));
                    exited = true;
                }
            }
        }
        if exited {
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}

/// Drive `ui: "rpc"`: dispatch worker notifications into the pane, and wire
/// the page's `form.submit` button back to the worker's stdin, toggling
/// layer-shell keyboard exclusivity around the round trip (binding pkexec
/// focus-handoff behaviour from the task brief).
fn run_rpc_mode(canvas: &Rc<Canvas>, worker: &Rc<RefCell<Worker>>) {
    let pending_form_id = Rc::new(RefCell::new(None::<i64>));
    let next_id = Rc::new(RefCell::new(0i64));

    {
        // A second, distinct `Rc` clone for the closure: `canvas` itself is
        // the receiver of `on_form_submit` below, so the closure passed to
        // it can't also capture-by-move the same binding used for that call.
        let canvas_handle = canvas.clone();
        let worker = worker.clone();
        let pending_form_id = pending_form_id.clone();
        let next_id = next_id.clone();
        canvas.on_form_submit(move |values| {
            let id = {
                let mut next_id = next_id.borrow_mut();
                let id = *next_id;
                *next_id += 1;
                id
            };
            *pending_form_id.borrow_mut() = Some(id);
            canvas_handle.set_keyboard_exclusive(false);
            let request = rpc::form_submit_request(id, &values);
            let _ = worker.borrow_mut().send(&request);
        });
    }

    let canvas = canvas.clone();
    let worker = worker.clone();
    glib::source::timeout_add_local(Duration::from_millis(16), move || {
        let mut exited = false;
        while let Ok(line) = worker.borrow().lines.try_recv() {
            match line {
                WorkerLine::Stdout(text) => handle_rpc_line(&canvas, &pending_form_id, &text),
                WorkerLine::Stderr(_) => {}
                WorkerLine::Exited(_) => exited = true,
            }
        }
        if exited {
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}

fn handle_rpc_line(canvas: &Rc<Canvas>, pending_form_id: &Rc<RefCell<Option<i64>>>, line: &str) {
    match rpc::parse_incoming(line) {
        Ok(rpc::IncomingMessage::Notification { method, params }) => {
            match dispatch_notification(&method, &params) {
                CanvasEvent::Render(component) => render_component(canvas, &component),
                CanvasEvent::LogAppend(text) => {
                    let html = ansi::to_html(&ansi::parse(&text));
                    canvas.eval(&shell::call_append_log(&format!("{html}\n")));
                }
                CanvasEvent::Error(message) => render_error(canvas, &message),
            }
        }
        Ok(rpc::IncomingMessage::Response(response)) => {
            let mut pending = pending_form_id.borrow_mut();
            if *pending == Some(response.id) {
                *pending = None;
                canvas.set_keyboard_exclusive(true);
                if let Err(err) = response.outcome {
                    render_error(canvas, &err.message);
                }
            }
        }
        Err(err) => render_error(canvas, &err.to_string()),
    }
}

fn render_component(canvas: &Canvas, component: &Component) {
    match component {
        Component::Detail { markdown: source } => {
            canvas.eval(&shell::call_render_detail(&markdown::render(source)));
        }
        Component::Log => canvas.eval(&shell::call_render_log()),
        Component::Form {
            fields,
            submit_label,
        } => match serde_json::to_string(fields) {
            Ok(fields_json) => {
                canvas.eval(&shell::call_render_form(
                    &fields_json,
                    submit_label.as_deref(),
                ));
            }
            Err(err) => render_error(canvas, &format!("could not serialize form fields: {err}")),
        },
    }
}

fn render_error(canvas: &Canvas, message: &str) {
    canvas.eval(&shell::call_render_detail(&markdown::render(&format!(
        "**Error:** {message}"
    ))));
}
