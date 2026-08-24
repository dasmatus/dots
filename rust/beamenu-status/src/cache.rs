//! The snapshot file the daemon writes and the launcher reads.
//!
//! One small JSON document in the launcher's state directory. The launcher
//! opens it on a keystroke, so writing must never leave a half-written file
//! where a reader can see it — hence the temp-and-rename below, which is
//! atomic within a filesystem.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::model::Snapshot;

/// How old a snapshot may be before a reader should say so.
///
/// Three times the daemon's five-second tick: long enough that an ordinary late
/// write is not called stale, short enough that a dead daemon is noticed while
/// the reading still looks plausible.
pub const STALE_AFTER_SECONDS: u64 = 15;

/// Path of the snapshot inside `state_dir`.
#[must_use]
pub fn path(state_dir: &Path) -> PathBuf {
    state_dir.join("status.json")
}

/// `$XDG_STATE_HOME/beamenu`, where the snapshot lives.
///
/// The launcher computes this for itself, and deliberately so: the dependency
/// runs from the launcher to this crate, not back. But every *reader* of the
/// snapshot needs the same answer, and there are now two of them, the dashboard
/// worker and `dots-osd`, so the readers share one copy here rather than each
/// carrying their own and drifting.
#[must_use]
pub fn state_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("beamenu")
}

/// Read the snapshot, or `None` if it is missing or unparseable.
///
/// Tolerant on purpose, matching how the launcher already treats quicklinks and
/// plugin manifests: a snapshot written by an older build, or truncated by a
/// full disk, costs the rows it described rather than the launcher.
#[must_use]
pub fn load(path: &Path) -> Option<Snapshot> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Write `snapshot` atomically.
///
/// # Errors
/// Fails when the state directory cannot be created, or the temp file cannot be
/// written or renamed into place.
pub fn store(path: &Path, snapshot: &Snapshot) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("could not create {}", parent.display()))?;
    }

    let encoded =
        serde_json::to_string(snapshot).context("could not encode the status snapshot")?;

    // Same directory as the target, so the rename stays within one filesystem
    // and therefore stays atomic.
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, encoded)
        .with_context(|| format!("could not write {}", temp.display()))?;
    std::fs::rename(&temp, path)
        .with_context(|| format!("could not replace {}", path.display()))?;
    Ok(())
}

/// Whether `snapshot` is old enough that a reader should mark it.
#[must_use]
pub fn is_stale(snapshot: &Snapshot, now: u64) -> bool {
    now.saturating_sub(snapshot.captured_at) > STALE_AFTER_SECONDS
}
