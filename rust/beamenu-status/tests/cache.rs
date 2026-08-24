//! The snapshot file: round-tripping, tolerance, and staleness.

use beamenu_status::cache;
use beamenu_status::model::{Disk, Network, NetworkKind, Service, Snapshot, Volume, Vpn};

fn sample() -> Snapshot {
    Snapshot {
        captured_at: 1_700_000_000,
        volume: Some(Volume {
            percent: 35,
            muted: false,
        }),
        microphone: Some(Volume {
            percent: 100,
            muted: true,
        }),
        network: Some(Network {
            kind: NetworkKind::Wifi,
            name: "HOME".into(),
            device: "wlp3s0".into(),
        }),
        vpn: Some(Vpn {
            connected: true,
            server: Some("ProtonVPN SK#25".into()),
        }),
        mail_bridge: Some(Service { active: true }),
        disks: vec![Disk {
            path: "/home".into(),
            used: 139_908_759_552,
            total: 493_837_352_960,
        }],
    }
}

#[test]
fn a_snapshot_survives_a_round_trip() {
    let dir = tempdir();
    let path = cache::path(&dir);

    cache::store(&path, &sample()).expect("a snapshot writes");
    let read = cache::load(&path).expect("what was written reads back");

    assert_eq!(read, sample());
}

#[test]
fn storing_creates_the_state_directory() {
    let dir = tempdir().join("not").join("yet").join("there");
    let path = cache::path(&dir);

    cache::store(&path, &sample()).expect("a missing parent is created");
    assert!(path.exists());
}

#[test]
fn storing_leaves_no_temp_file_behind() {
    let dir = tempdir();
    let path = cache::path(&dir);
    cache::store(&path, &sample()).expect("a snapshot writes");

    let leftovers: Vec<_> = std::fs::read_dir(&dir)
        .expect("the state dir reads")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "tmp"))
        .map(|path| path.display().to_string())
        .collect();

    assert!(leftovers.is_empty(), "found {leftovers:?}");
}

#[test]
fn a_missing_or_corrupt_snapshot_reads_as_absent_rather_than_failing() {
    let dir = tempdir();
    assert!(cache::load(&cache::path(&dir)).is_none());

    let path = cache::path(&dir);
    std::fs::write(&path, "{ this is not json").expect("the fixture writes");
    assert!(cache::load(&path).is_none());
}

#[test]
fn a_snapshot_from_an_older_build_still_loads() {
    // Every field is #[serde(default)], so a snapshot written before a metric
    // existed costs that metric's row, not every row.
    let dir = tempdir();
    let path = cache::path(&dir);
    std::fs::write(&path, r#"{"captured_at":1700000000}"#).expect("the fixture writes");

    let read = cache::load(&path).expect("a sparse snapshot loads");
    assert_eq!(read.captured_at, 1_700_000_000);
    assert!(read.volume.is_none());
    assert!(read.disks.is_empty());
}

#[test]
fn staleness_is_measured_against_the_capture_time() {
    let snapshot = sample();
    let captured = snapshot.captured_at;

    assert!(!cache::is_stale(&snapshot, captured));
    assert!(!cache::is_stale(
        &snapshot,
        captured + cache::STALE_AFTER_SECONDS
    ));
    assert!(cache::is_stale(
        &snapshot,
        captured + cache::STALE_AFTER_SECONDS + 1
    ));
}

#[test]
fn a_clock_that_went_backwards_does_not_report_staleness() {
    // saturating_sub, so an NTP step backwards cannot underflow into a huge
    // age and mark every reading stale.
    let snapshot = sample();
    assert!(!cache::is_stale(&snapshot, snapshot.captured_at - 5_000));
}

/// A scratch directory that lives as long as the test binary.
///
/// `tempfile` is a dev-dependency of the launcher crate, not this one, and one
/// directory per test run is not worth another dependency.
fn tempdir() -> std::path::PathBuf {
    let base = std::env::temp_dir().join(format!(
        "beamenu-status-test-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&base).expect("a scratch dir is created");
    base
}
