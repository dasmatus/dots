//! The warm desktop-entry index: when it rescans, and when it must not.

use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use beamenu::index::{AppCache, Index};

/// Write one `.desktop` file under `dir/applications`, the subdirectory
/// [`beamenu::providers::apps::scan`] actually reads for an XDG data
/// directory — mirroring `data_dirs()`, `dir` here stands in for something
/// like `/usr/share`, not `/usr/share/applications` itself.
fn write_entry(dir: &std::path::Path, file: &str, name: &str) {
    let apps = dir.join("applications");
    std::fs::create_dir_all(&apps).unwrap();
    std::fs::write(
        apps.join(file),
        format!("[Desktop Entry]\nType=Application\nName={name}\nExec=/bin/true\n"),
    )
    .unwrap();
}

#[test]
fn first_revalidate_scans_and_reports_that_it_did() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);

    assert!(index.revalidate(), "an unscanned index must scan");
    assert_eq!(index.entries().len(), 1);
}

#[test]
fn an_unchanged_directory_is_not_rescanned() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);
    index.revalidate();

    assert!(!index.revalidate(), "nothing changed, so nothing to rescan");
}

#[test]
fn a_new_entry_makes_the_index_stale() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);
    index.revalidate();

    // Directory mtime has one-second granularity on some filesystems, so
    // stamp the `applications` subdirectory forward explicitly rather than
    // racing it.
    //
    // `filetime` is not a dev-dependency here, so the stamp is forced through
    // `File::set_modified` on a directory handle instead.
    write_entry(dir.path(), "b.desktop", "Beta");
    let forward = SystemTime::now() + Duration::from_secs(5);
    std::fs::File::open(dir.path().join("applications"))
        .unwrap()
        .set_modified(forward)
        .unwrap();

    assert!(index.revalidate(), "a changed directory must rescan");
    assert_eq!(index.entries().len(), 2);
}

#[test]
fn a_missing_directory_is_not_an_error() {
    let mut index = Index::with_dirs(vec![PathBuf::from("/nonexistent/beamenu-test")]);
    index.revalidate();
    assert!(index.entries().is_empty());
}

#[test]
fn icon_lookups_are_memoized_per_name() {
    let cache = AppCache::default();
    // Two lookups of a name that resolves to nothing must agree, and the
    // second must not re-probe the icon themes. Behaviour is observable only
    // through equality here; the memo table is an implementation detail.
    assert_eq!(
        cache.icon("definitely-not-an-icon"),
        cache.icon("definitely-not-an-icon")
    );
}

#[test]
fn revalidate_then_icon_does_not_hold_a_ref_across_the_borrow_mut() {
    // AppCache::entries clones out of the RefCell precisely so nothing keeps
    // a Ref alive across an icon() call, which takes borrow_mut. Holding one
    // across the other panics the RefCell at runtime; a caller that only
    // calls each method once is not enough to catch that, so this drives them
    // back-to-back the way the apps provider actually does: read the
    // snapshot, then resolve an icon for every entry found in it, all while
    // the `entries()` return value from the first call is still in scope.
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let cache = AppCache::with_dirs(vec![dir.path().to_path_buf()]);

    assert!(cache.revalidate());
    let entries = cache.entries();
    assert_eq!(entries.len(), 1);
    for entry in entries.values() {
        // Would panic with a `BorrowMutError` if `entries()` above still held
        // a live `Ref` into the same `RefCell` that `icon()` needs
        // `borrow_mut()` on.
        let _ = entry.icon.as_deref().and_then(|name| cache.icon(name));
    }
    assert!(!cache.revalidate(), "nothing changed since the scan above");
}
