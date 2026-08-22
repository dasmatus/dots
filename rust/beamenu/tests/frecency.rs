//! Usage weighting: recency and frequency both have to matter.

use beamenu::frecency::Frecency;

const DAY: u64 = 86_400;
const NOW: u64 = 1_000 * DAY;

#[test]
fn an_unknown_id_gets_no_boost() {
    let store = Frecency::default();
    assert_eq!(store.boost_at("never-launched", NOW), 0);
}

#[test]
fn more_launches_score_higher() {
    let mut store = Frecency::default();
    store.record_at("once", NOW);
    for _ in 0..10 {
        store.record_at("often", NOW);
    }
    assert!(store.boost_at("often", NOW) > store.boost_at("once", NOW));
}

#[test]
fn recent_use_beats_old_use_at_equal_counts() {
    let mut store = Frecency::default();
    for _ in 0..5 {
        store.record_at("recent", NOW - DAY);
        store.record_at("stale", NOW - 90 * DAY);
    }
    assert!(store.boost_at("recent", NOW) > store.boost_at("stale", NOW));
}

#[test]
fn the_boost_is_capped() {
    let mut store = Frecency::default();
    for _ in 0..1000 {
        store.record_at("hammered", NOW);
    }
    // The cap is what stops history from making an entry unbeatable.
    assert!(store.boost_at("hammered", NOW) <= 60);
}

#[test]
fn decay_is_gradual_rather_than_a_cliff() {
    let mut store = Frecency::default();
    store.record_at("thing", NOW - 14 * DAY);
    let half_life = store.boost_at("thing", NOW);

    let mut fresh = Frecency::default();
    fresh.record_at("thing", NOW);
    let full = fresh.boost_at("thing", NOW);

    assert!(half_life > 0, "an entry a fortnight old still counts");
    assert!(half_life < full);
}

#[test]
fn survives_a_save_and_load_round_trip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("nested/frecency.json");

    let mut store = Frecency::default();
    store.record_at("kitty", NOW);
    store.save(&path).unwrap();

    let reloaded = Frecency::load(&path);
    assert_eq!(
        reloaded.boost_at("kitty", NOW),
        store.boost_at("kitty", NOW)
    );
}

#[test]
fn a_corrupt_store_reads_as_empty_history() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("frecency.json");
    std::fs::write(&path, "{ this is not json").unwrap();

    // Losing ranking history must never stop the launcher from opening.
    assert_eq!(Frecency::load(&path).boost_at("anything", NOW), 0);
}

#[test]
fn a_missing_store_reads_as_empty_history() {
    let store = Frecency::load(std::path::Path::new("/nonexistent/frecency.json"));
    assert_eq!(store.boost_at("anything", NOW), 0);
}
