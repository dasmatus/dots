//! What the daemon publishes about itself. The bus and the panel both need a
//! live session, so neither appears here; the state they read does.

use std::sync::atomic::Ordering;

use beamenu::daemon::publish;
use beamenu::ipc::Shared;

#[test]
fn publish_copies_the_launchers_counts_into_the_shared_cell() {
    let app = beamenu::App::new();
    let shared = Shared::new();
    publish(&app, &shared);

    assert_eq!(shared.providers.load(Ordering::SeqCst), app.providers.len());
    assert!(
        shared.providers.load(Ordering::SeqCst) >= 10,
        "the ten built-in providers are always registered"
    );
}

#[test]
fn publish_republishes_the_terminal_so_a_reconfigured_one_takes_effect() {
    let mut app = beamenu::App::new();
    let shared = Shared::new();
    app.ctx.config.terminal = "some-other-terminal".to_string();
    publish(&app, &shared);

    assert_eq!(
        shared.terminal.read().unwrap().as_str(),
        "some-other-terminal"
    );
}

#[test]
fn publish_is_idempotent() {
    let app = beamenu::App::new();
    let shared = Shared::new();
    publish(&app, &shared);
    let first = shared.apps.load(Ordering::SeqCst);
    publish(&app, &shared);

    assert_eq!(shared.apps.load(Ordering::SeqCst), first);
}

#[test]
fn refresh_carries_the_warm_cache_across_the_rebuild() {
    // The whole point of the daemon: `refresh` replaces the App wholesale
    // before every show, and the desktop-entry scan is the one piece too
    // expensive to redo. A fresh cache would report that it had to scan, so
    // "nothing to rescan" is what proves the old one survived the rebuild —
    // asserting the entry count would not, since a rescan reaches the same
    // number.
    let mut app = beamenu::App::new();
    app.refresh();

    assert!(
        !app.ctx.apps.revalidate(),
        "refresh must move the scanned cache into the new App, not start over"
    );
}
