//! The warm desktop-entry index.
//!
//! A one-shot launcher could afford to walk every `applications` directory and
//! probe the icon themes on each keystroke: the process died a moment later
//! and nothing outlived it. A resident daemon cannot, and it should not have
//! to — the answer only changes when a package is installed or removed.
//!
//! So the scan moves behind [`Index`], revalidated once per *show* by
//! comparing each watched directory's `applications` subdirectory mtime
//! against the stamp taken when it was last read. That keeps the observable
//! freshness exactly where it was — a new application appears the next time
//! the launcher opens — while taking the filesystem out of the keystroke path
//! entirely.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::time::SystemTime;

use crate::providers::apps::{data_dirs, resolve_icon, scan, DesktopEntry};

/// Desktop entries and resolved icon paths, with the stamps that say when to
/// look again.
pub struct Index {
    dirs: Vec<PathBuf>,
    /// Last-seen mtime of each `dirs` entry's `applications` subdirectory —
    /// the directory [`crate::providers::apps::scan`] actually reads — `None`
    /// when it does not exist. A directory appearing later is a change like
    /// any other.
    ///
    /// Watching `dirs` itself would not do: on Linux, adding or removing a
    /// file inside a subdirectory does not touch the parent directory's
    /// mtime, only the subdirectory's own. `scan` reads `applications/`, so
    /// that is the mtime that has to move for a new entry to be noticed.
    stamps: Vec<Option<SystemTime>>,
    entries: BTreeMap<String, DesktopEntry>,
    icons: HashMap<String, Option<PathBuf>>,
    scanned: bool,
}

impl Default for Index {
    fn default() -> Self {
        Self::with_dirs(data_dirs())
    }
}

impl Index {
    /// An unscanned index over `dirs`.
    #[must_use]
    pub fn with_dirs(dirs: Vec<PathBuf>) -> Self {
        Self {
            stamps: vec![None; dirs.len()],
            dirs,
            entries: BTreeMap::new(),
            icons: HashMap::new(),
            scanned: false,
        }
    }

    fn stamps_now(&self) -> Vec<Option<SystemTime>> {
        self.dirs
            .iter()
            .map(|dir| {
                std::fs::metadata(dir.join("applications"))
                    .and_then(|m| m.modified())
                    .ok()
            })
            .collect()
    }

    /// Rescan if any watched directory changed, or if nothing was ever
    /// scanned. Returns whether a rescan happened.
    ///
    /// The icon memo is cleared alongside the entries: an icon theme usually
    /// lands in the same package as the desktop file that names it, so a
    /// negative lookup cached from before an install would otherwise stick.
    pub fn revalidate(&mut self) -> bool {
        let now = self.stamps_now();
        if self.scanned && now == self.stamps {
            return false;
        }
        self.entries = scan(&self.dirs);
        self.icons.clear();
        self.stamps = now;
        self.scanned = true;
        true
    }

    #[must_use]
    pub fn entries(&self) -> &BTreeMap<String, DesktopEntry> {
        &self.entries
    }

    /// Resolve an icon name, remembering the answer — including a negative
    /// one, which costs the same directory walk to establish as a hit.
    pub fn icon(&mut self, name: &str) -> Option<PathBuf> {
        if let Some(hit) = self.icons.get(name) {
            return hit.clone();
        }
        let resolved = resolve_icon(name, &self.dirs);
        self.icons.insert(name.to_string(), resolved.clone());
        resolved
    }
}

/// Shared handle to an [`Index`] that a `&Ctx` can still write through.
///
/// [`crate::providers::Provider::query`] takes `&Ctx`, because a provider is
/// meant to be a pure function of the query. Memoizing an icon lookup is the
/// one place that has to write, and it is invisible from outside — the same
/// call returns the same answer either way — which is exactly what interior
/// mutability is for. Single-threaded by construction: the UI owns the `Ctx`.
#[derive(Default)]
pub struct AppCache(RefCell<Index>);

impl AppCache {
    /// An unscanned cache over `dirs`. Test seam, mirroring
    /// [`Index::with_dirs`].
    #[must_use]
    pub fn with_dirs(dirs: Vec<PathBuf>) -> Self {
        Self(RefCell::new(Index::with_dirs(dirs)))
    }

    /// See [`Index::revalidate`].
    pub fn revalidate(&self) -> bool {
        self.0.borrow_mut().revalidate()
    }

    /// A snapshot of the entries. Cloned rather than borrowed so no `Ref`
    /// escapes into provider code, where holding one across an `icon` call
    /// would panic the `RefCell`.
    #[must_use]
    pub fn entries(&self) -> BTreeMap<String, DesktopEntry> {
        self.0.borrow().entries().clone()
    }

    /// See [`Index::icon`].
    #[must_use]
    pub fn icon(&self, name: &str) -> Option<PathBuf> {
        self.0.borrow_mut().icon(name)
    }
}
