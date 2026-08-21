//! hyprtile-wallpaperd backend: mode mapping, the pure argv builder, the
//! stop-old/spawn-new apply orchestrator (against a fake process backend),
//! pidfile parsing/liveness, and the hyprtile `config.json` sync. Ports
//! `tests/awww.rs`.

mod common;

use std::sync::Mutex;
use std::time::Duration;

use tempfile::tempdir;
use wallpaper_tui::wallpaperd::{
    apply_wallpaper, is_pid_alive, map_mode, merge_hyprtile_config, read_pid, stop_old_daemon,
    sync_hyprtile_config, wallpaperd_args, Group, WallpaperdBackend,
};

/// A fake process table: `alive` holds the pids currently considered live;
/// `terminate` removes the pid (simulating a process that dies immediately
/// on `SIGTERM`, so `stop_old_daemon`'s poll loop exits on the very first
/// check — no real sleeping in these tests).
#[derive(Default)]
struct FakeBackend {
    alive: Mutex<Vec<i32>>,
    terminated: Mutex<Vec<i32>>,
    spawns: Mutex<Vec<Vec<String>>>,
    spawn_ok: bool,
}

impl FakeBackend {
    fn new(alive: &[i32]) -> Self {
        Self {
            alive: Mutex::new(alive.to_vec()),
            terminated: Mutex::new(Vec::new()),
            spawns: Mutex::new(Vec::new()),
            spawn_ok: true,
        }
    }
}

impl WallpaperdBackend for FakeBackend {
    fn is_alive(&self, pid: i32) -> bool {
        self.alive.lock().unwrap().contains(&pid)
    }
    fn terminate(&self, pid: i32) {
        self.terminated.lock().unwrap().push(pid);
        self.alive.lock().unwrap().retain(|p| *p != pid);
    }
    fn spawn(&self, argv: &[String]) -> bool {
        self.spawns.lock().unwrap().push(argv.to_vec());
        self.spawn_ok
    }
}

/// A backend whose pids never die — exercises `stop_old_daemon`'s timeout
/// path. Uses tiny durations so the test still runs in well under a second.
struct NeverDies;

impl WallpaperdBackend for NeverDies {
    fn is_alive(&self, _pid: i32) -> bool {
        true
    }
    fn terminate(&self, _pid: i32) {}
    fn spawn(&self, _argv: &[String]) -> bool {
        true
    }
}

fn group(output: &str, path: &str, mode: &str, fill_color: &str) -> Group {
    Group {
        output: output.to_string(),
        path: path.to_string(),
        mode: mode.to_string(),
        fill_color: fill_color.to_string(),
    }
}

#[test]
fn map_mode_swaybg_to_wallpaperd() {
    assert_eq!(map_mode("fill"), "cover");
    assert_eq!(map_mode("stretch"), "stretch");
    assert_eq!(map_mode("fit"), "contain");
    assert_eq!(map_mode("center"), "center");
    assert_eq!(map_mode("tile"), "cover", "no tile support -> cover");
    assert_eq!(map_mode("unknown"), "cover", "unknown -> cover default");
}

#[test]
fn wallpaperd_args_builds_expected_argv() {
    let pidfile = std::path::Path::new("/home/u/.hyprtile/wallpaperd.pid");
    let args = wallpaperd_args("/w/p.jpg", "fit", pidfile);
    assert_eq!(args[0], "hyprtile-wallpaperd");
    let idx = |flag: &str| args.iter().position(|a| a == flag).expect(flag) + 1;
    assert_eq!(args[idx("--image")], "/w/p.jpg");
    assert_eq!(args[idx("--mode")], "contain");
    assert_eq!(args[idx("--pidfile")], "/home/u/.hyprtile/wallpaperd.pid");
    assert!(!args.contains(&"-o".to_string()), "no per-output targeting");
}

#[test]
fn read_pid_parses_trimmed_int() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    std::fs::write(&pidfile, "4242\n").unwrap();
    assert_eq!(read_pid(&pidfile), Some(4242));
}

#[test]
fn read_pid_missing_or_garbage_is_none() {
    let dir = tempdir().unwrap();
    let missing = dir.path().join("nope.pid");
    assert_eq!(read_pid(&missing), None);

    let garbage = dir.path().join("garbage.pid");
    std::fs::write(&garbage, "not-a-pid").unwrap();
    assert_eq!(read_pid(&garbage), None);
}

#[test]
fn is_pid_alive_self_true_bogus_false() {
    assert!(is_pid_alive(std::process::id().cast_signed()));
    assert!(!is_pid_alive(i32::MAX));
}

#[test]
fn stop_old_daemon_terminates_live_pid() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    std::fs::write(&pidfile, "777").unwrap();
    let backend = FakeBackend::new(&[777]);

    stop_old_daemon(
        &backend,
        &pidfile,
        Duration::from_millis(1),
        Duration::from_millis(50),
    );

    assert_eq!(*backend.terminated.lock().unwrap(), vec![777]);
    assert!(!backend.is_alive(777));
}

#[test]
fn stop_old_daemon_missing_pidfile_is_noop() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("nope.pid");
    let backend = FakeBackend::new(&[]);

    stop_old_daemon(
        &backend,
        &pidfile,
        Duration::from_millis(1),
        Duration::from_millis(50),
    );

    assert!(backend.terminated.lock().unwrap().is_empty());
}

#[test]
fn stop_old_daemon_dead_pid_skips_terminate() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    std::fs::write(&pidfile, "999").unwrap();
    let backend = FakeBackend::new(&[]); // 999 not in the alive table

    stop_old_daemon(
        &backend,
        &pidfile,
        Duration::from_millis(1),
        Duration::from_millis(50),
    );

    assert!(
        backend.terminated.lock().unwrap().is_empty(),
        "already-dead pid should not be signaled"
    );
}

#[test]
fn stop_old_daemon_gives_up_after_timeout() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    std::fs::write(&pidfile, "1").unwrap();
    let backend = NeverDies;

    let start = std::time::Instant::now();
    stop_old_daemon(
        &backend,
        &pidfile,
        Duration::from_millis(1),
        Duration::from_millis(5),
    );
    assert!(
        start.elapsed() < Duration::from_millis(200),
        "must give up promptly, not hang"
    );
}

#[test]
fn apply_wallpaper_stops_old_and_spawns_new() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    std::fs::write(&pidfile, "555").unwrap();
    let backend = FakeBackend::new(&[555]);

    let groups = [group("eDP-1", "/w/a.jpg", "fit", "#000000")];
    let applied = apply_wallpaper(&backend, &groups, &pidfile);

    assert!(applied);
    assert_eq!(*backend.terminated.lock().unwrap(), vec![555]);
    let spawns = backend.spawns.lock().unwrap().clone();
    assert_eq!(spawns.len(), 1);
    assert_eq!(spawns[0], wallpaperd_args("/w/a.jpg", "fit", &pidfile));
}

#[test]
fn apply_wallpaper_only_first_group_is_rendered() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    let backend = FakeBackend::new(&[]);

    let groups = [
        group("eDP-1", "/w/a.jpg", "fill", "#000000"),
        group("HDMI-1", "/w/b.jpg", "center", "#d2a1a1"),
    ];
    apply_wallpaper(&backend, &groups, &pidfile);

    let spawns = backend.spawns.lock().unwrap().clone();
    assert_eq!(spawns.len(), 1, "wallpaperd has no per-output targeting");
    assert!(spawns[0].contains(&"/w/a.jpg".to_string()));
    assert!(!spawns[0].contains(&"/w/b.jpg".to_string()));
}

#[test]
fn apply_wallpaper_empty_groups_noop() {
    let dir = tempdir().unwrap();
    let pidfile = dir.path().join("wallpaperd.pid");
    let backend = FakeBackend::new(&[]);

    assert!(!apply_wallpaper(&backend, &[], &pidfile));
    assert!(backend.spawns.lock().unwrap().is_empty());
}

#[test]
fn merge_hyprtile_config_sets_keys_and_preserves_others() {
    let doc = serde_json::json!({
        "wallpaper": 0,
        "wallpaper_file": "",
        "wallpaper_mode": "cover",
        "unrelated": {"nested": true},
        "theme": "dark",
    });
    let merged = merge_hyprtile_config(doc, "/w/new.jpg", "contain");
    assert_eq!(merged["wallpaper"], 1);
    assert_eq!(merged["wallpaper_file"], "/w/new.jpg");
    assert_eq!(merged["wallpaper_mode"], "contain");
    assert_eq!(merged["theme"], "dark");
    assert_eq!(merged["unrelated"]["nested"], true);
}

#[test]
fn merge_hyprtile_config_non_object_is_unchanged() {
    let doc = serde_json::json!([1, 2, 3]);
    let merged = merge_hyprtile_config(doc.clone(), "/w/new.jpg", "contain");
    assert_eq!(merged, doc);
}

#[test]
fn sync_hyprtile_config_updates_existing_file() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("config.json");
    std::fs::write(
        &path,
        serde_json::to_string_pretty(&serde_json::json!({
            "wallpaper": 0,
            "wallpaper_file": "",
            "wallpaper_mode": "cover",
            "some_other_setting": 42,
        }))
        .unwrap(),
    )
    .unwrap();

    sync_hyprtile_config(&path, "/w/new.jpg", "fit");

    let text = std::fs::read_to_string(&path).unwrap();
    let doc: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(doc["wallpaper"], 1);
    assert_eq!(doc["wallpaper_file"], "/w/new.jpg");
    assert_eq!(doc["wallpaper_mode"], "contain", "mode mapped, not raw");
    assert_eq!(doc["some_other_setting"], 42);
}

#[test]
fn sync_hyprtile_config_missing_file_is_silent_noop() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("config.json");
    sync_hyprtile_config(&path, "/w/new.jpg", "fit");
    assert!(!path.exists(), "must not create the file");
}

#[test]
fn sync_hyprtile_config_malformed_file_is_left_untouched() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("config.json");
    std::fs::write(&path, "{ not json").unwrap();
    sync_hyprtile_config(&path, "/w/new.jpg", "fit");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
}
