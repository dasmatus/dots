//! The awww backend: mode mapping, argv construction, daemon handling and
//! the apply orchestrator.

use std::cell::RefCell;
use std::time::Duration;

use wallpaper_tui::awww::{
    apply_wallpaper, ensure_daemon, map_mode, awww_args, Group, AwwwBackend, Transition,
};

fn group(output: &str, path: &str, mode: &str) -> Group {
    Group {
        output: output.to_string(),
        path: path.to_string(),
        mode: mode.to_string(),
        fill_color: "#000000".to_string(),
    }
}

/// Records what the orchestrator asked for, and can pretend the daemon is
/// absent for a fixed number of probes before coming up.
struct FakeAwww {
    /// Probes remaining before `daemon_running` starts reporting true.
    probes_until_up: RefCell<u32>,
    /// Set when the daemon should never come up, even after a spawn.
    never_up: bool,
    /// Set when spawning the daemon should fail outright.
    spawn_fails: bool,
    /// Argv of every command run, in order.
    ran: RefCell<Vec<Vec<String>>>,
    spawned: RefCell<u32>,
    /// Commands whose first argument matches this fail.
    fail_output: Option<String>,
}

impl FakeAwww {
    fn up() -> Self {
        Self {
            probes_until_up: RefCell::new(0),
            never_up: false,
            spawn_fails: false,
            ran: RefCell::new(Vec::new()),
            spawned: RefCell::new(0),
            fail_output: None,
        }
    }

    fn down_for(probes: u32) -> Self {
        Self {
            probes_until_up: RefCell::new(probes),
            ..Self::up()
        }
    }
}

impl AwwwBackend for FakeAwww {
    fn daemon_running(&self) -> bool {
        if self.never_up {
            return false;
        }
        let mut left = self.probes_until_up.borrow_mut();
        if *left == 0 {
            true
        } else {
            *left -= 1;
            false
        }
    }

    fn spawn_daemon(&self) -> bool {
        *self.spawned.borrow_mut() += 1;
        !self.spawn_fails
    }

    fn run(&self, argv: &[String]) -> bool {
        self.ran.borrow_mut().push(argv.to_vec());
        match &self.fail_output {
            Some(bad) => !argv.contains(bad),
            None => true,
        }
    }
}

// --- mode mapping ---

#[test]
fn maps_swaybg_modes_to_awww_resize_values() {
    assert_eq!(map_mode("fit"), "fit");
    assert_eq!(map_mode("stretch"), "stretch");
    assert_eq!(map_mode("center"), "no");
    assert_eq!(map_mode("fill"), "crop");
}

#[test]
fn tile_and_unknown_modes_degrade_to_crop() {
    // awww has no tile; crop is the same degrade the old backend chose.
    assert_eq!(map_mode("tile"), "crop");
    assert_eq!(map_mode("nonsense"), "crop");
    assert_eq!(map_mode(""), "crop");
}

// --- argv ---

#[test]
fn argv_targets_one_output_and_carries_the_transition() {
    let argv = awww_args(&group("DP-1", "/w/a.png", "fit"), &Transition::default());
    let joined = argv.join(" ");

    assert_eq!(argv[0], "awww");
    assert_eq!(argv[1], "img");
    assert_eq!(argv[2], "/w/a.png");
    assert!(joined.contains("--outputs DP-1"), "{joined}");
    assert!(joined.contains("--resize fit"), "{joined}");
    assert!(joined.contains("--transition-type fade"), "{joined}");
    assert!(joined.contains("--transition-duration 1"), "{joined}");
    assert!(joined.contains("--transition-fps 60"), "{joined}");
}

#[test]
fn argv_honours_a_custom_transition() {
    let transition = Transition {
        kind: "wipe".into(),
        duration: "2".into(),
        fps: "30".into(),
    };
    let joined = awww_args(&group("eDP-1", "/w/b.png", "fill"), &transition).join(" ");
    assert!(joined.contains("--transition-type wipe"), "{joined}");
    assert!(joined.contains("--transition-duration 2"), "{joined}");
    assert!(joined.contains("--transition-fps 30"), "{joined}");
}

// --- daemon ---

#[test]
fn a_running_daemon_is_not_respawned() {
    let backend = FakeAwww::up();
    assert!(ensure_daemon(
        &backend,
        Duration::from_millis(50),
        Duration::from_millis(1)
    ));
    assert_eq!(*backend.spawned.borrow(), 0);
}

#[test]
fn a_missing_daemon_is_spawned_and_waited_for() {
    // awww-daemon takes a moment to bind its socket, so a fresh spawn must be
    // polled rather than assumed ready.
    let backend = FakeAwww::down_for(3);
    assert!(ensure_daemon(
        &backend,
        Duration::from_millis(500),
        Duration::from_millis(1)
    ));
    assert_eq!(*backend.spawned.borrow(), 1);
}

#[test]
fn a_daemon_that_never_comes_up_fails_rather_than_hanging() {
    let backend = FakeAwww {
        never_up: true,
        ..FakeAwww::up()
    };
    assert!(!ensure_daemon(
        &backend,
        Duration::from_millis(20),
        Duration::from_millis(1)
    ));
}

#[test]
fn a_failed_spawn_gives_up_immediately() {
    let backend = FakeAwww {
        never_up: true,
        spawn_fails: true,
        ..FakeAwww::up()
    };
    assert!(!ensure_daemon(
        &backend,
        Duration::from_millis(500),
        Duration::from_millis(1)
    ));
    assert_eq!(*backend.spawned.borrow(), 1);
}

// --- apply ---

#[test]
fn every_output_gets_its_own_wallpaper() {
    // The hyprtile-wallpaperd backend collapsed to the first group because it
    // had no per-output targeting. awww does, so this must not regress.
    let backend = FakeAwww::up();
    let groups = vec![
        group("eDP-1", "/w/a.png", "fill"),
        group("DP-1", "/w/b.png", "fit"),
    ];

    assert!(apply_wallpaper(&backend, &groups, &Transition::default()));

    let ran = backend.ran.borrow();
    assert_eq!(ran.len(), 2);
    assert!(ran[0].contains(&"/w/a.png".to_string()));
    assert!(ran[0].contains(&"eDP-1".to_string()));
    assert!(ran[1].contains(&"/w/b.png".to_string()));
    assert!(ran[1].contains(&"DP-1".to_string()));
}

#[test]
fn applying_nothing_is_a_failure_not_a_no_op_success() {
    let backend = FakeAwww::up();
    assert!(!apply_wallpaper(&backend, &[], &Transition::default()));
    assert!(backend.ran.borrow().is_empty());
}

#[test]
fn apply_starts_the_daemon_when_it_is_down() {
    let backend = FakeAwww::down_for(1);
    let groups = vec![group("eDP-1", "/w/a.png", "fill")];

    assert!(apply_wallpaper(&backend, &groups, &Transition::default()));
    assert_eq!(*backend.spawned.borrow(), 1);
    assert_eq!(backend.ran.borrow().len(), 1);
}

#[test]
fn apply_reports_failure_without_skipping_the_remaining_outputs() {
    // A partial failure still leaves the successful outputs changed, so every
    // group must be attempted even after one fails.
    let backend = FakeAwww {
        fail_output: Some("eDP-1".to_string()),
        ..FakeAwww::up()
    };
    let groups = vec![
        group("eDP-1", "/w/a.png", "fill"),
        group("DP-1", "/w/b.png", "fit"),
    ];

    assert!(!apply_wallpaper(&backend, &groups, &Transition::default()));
    assert_eq!(backend.ran.borrow().len(), 2);
}

#[test]
fn apply_does_not_run_anything_when_the_daemon_cannot_start() {
    let backend = FakeAwww {
        never_up: true,
        ..FakeAwww::up()
    };
    let groups = vec![group("eDP-1", "/w/a.png", "fill")];

    assert!(!apply_wallpaper(&backend, &groups, &Transition::default()));
    assert!(backend.ran.borrow().is_empty());
}

#[test]
fn fill_color_loses_its_leading_hash() {
    // awww's --fill-color is RRGGBBAA with no hash; the config stores
    // CSS-style "#RRGGBB" because that is what every other colour uses.
    let mut g = group("eDP-1", "/w/a.png", "fit");
    g.fill_color = "#d2a1a1".to_string();
    let argv = awww_args(&g, &Transition::default());

    let index = argv.iter().position(|a| a == "--fill-color").unwrap();
    assert_eq!(argv[index + 1], "d2a1a1");
}
