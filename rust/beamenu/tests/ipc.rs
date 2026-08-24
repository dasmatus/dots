//! The daemon's D-Bus surface, exercised without a bus.
//!
//! Every method body is a plain function over plain arguments, which is what
//! makes this testable: the D-Bus layer contributes the name, the signature
//! and the error mapping, and none of those need a session bus to be right.

use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::Arc;

use beamenu::ipc::{run_command, Beamenu, Shared, Signal, BUS_NAME, OBJECT_PATH};

fn iface() -> (Beamenu, Arc<Shared>, mpsc::Receiver<Signal>) {
    let (tx, rx) = mpsc::channel();
    let shared = Arc::new(Shared::new());
    (Beamenu::new(tx, Arc::clone(&shared)), shared, rx)
}

#[test]
fn the_bus_name_and_path_agree_with_each_other() {
    assert_eq!(BUS_NAME, "dev.dots.Beamenu");
    assert_eq!(OBJECT_PATH, "/dev/dots/Beamenu");
    assert_eq!(
        OBJECT_PATH.trim_start_matches('/').replace('/', "."),
        BUS_NAME,
        "the object path is the bus name's path form, so one cannot drift"
    );
}

#[test]
fn show_signals_the_ui_thread() {
    let (iface, _shared, rx) = iface();
    assert!(iface.show(), "a hidden launcher accepts a show");
    assert_eq!(rx.try_recv().unwrap(), Signal::Show);
}

#[test]
fn show_while_visible_is_a_no_op_rather_than_a_queued_second_panel() {
    let (iface, shared, rx) = iface();
    shared.visible.store(true, Ordering::SeqCst);

    assert!(iface.show(), "a double keypress is not an error");
    assert!(
        rx.try_recv().is_err(),
        "nothing may be queued, or the panel reopens after the user dismissed it"
    );
}

#[test]
fn reload_signals_the_ui_thread() {
    let (iface, _shared, rx) = iface();
    assert!(iface.reload());
    assert_eq!(rx.try_recv().unwrap(), Signal::Reload);
}

#[test]
fn signalling_a_dead_ui_thread_reports_failure_rather_than_panicking() {
    let (iface, _shared, rx) = iface();
    drop(rx);
    assert!(
        !iface.show(),
        "a closed channel is a failed send, not an unwrap"
    );
}

#[test]
fn an_unknown_command_id_is_an_error_naming_it() {
    let err = run_command("definitely-not-a-command", "kitty")
        .expect_err("an unknown id cannot dispatch");
    assert!(
        err.contains("definitely-not-a-command"),
        "the message must name the id that was not found: {err}"
    );
}

#[test]
fn properties_read_through_to_what_the_ui_thread_published() {
    let (iface, shared, _rx) = iface();
    shared.apps.store(42, Ordering::SeqCst);
    shared.providers.store(11, Ordering::SeqCst);
    shared.visible.store(true, Ordering::SeqCst);

    assert_eq!(iface.apps(), 42);
    assert_eq!(iface.providers(), 11);
    assert!(iface.visible());
    assert_eq!(iface.version(), env!("CARGO_PKG_VERSION"));
}

#[test]
fn calling_with_no_daemon_is_an_error_the_caller_can_fall_back_from() {
    // Either there is no session bus in this environment, or there is one and
    // nobody owns the name. Both are the same answer to the caller. Point the
    // call at a bus address that cannot resolve, so this stays true even when
    // the developer running the suite happens to have a real beamenu daemon
    // on their session bus. Environment mutation is process-global, so this
    // must be the only test in the file that touches it.
    std::env::set_var("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent");
    assert!(beamenu::ipc::call("Show", None).is_err());
}
