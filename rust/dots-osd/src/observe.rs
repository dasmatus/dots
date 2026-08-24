//! The impure half of the watcher: read the world, hand it to [`crate::watch`].
//!
//! Nothing here forks. The expensive readings, `wpctl`, `nmcli`, `df`, are
//! already being taken every five seconds by `beamenu --status-daemon`, which
//! leaves them in a snapshot file; this reads that file rather than taking them
//! a second time. What is left is `/sys` for the battery and `/proc` for the
//! camera, both of which are microseconds.
//!
//! That makes the watcher a reader of someone else's poll, and the staleness
//! check below is what keeps that honest: a snapshot older than the poller's
//! own tolerance is dropped rather than diffed, so a dead poller shows as
//! silence instead of as a world where nothing ever changes.

use std::path::Path;

use beamenu_status::{cache, probe};

use crate::watch::{Camera, Observed};

/// Device nodes that mean "a camera is open".
///
/// A UVC webcam exposes more than one `video*` node, the capture node and a
/// metadata node, and an application holding either one has the camera. The
/// prefix therefore covers the family rather than naming `video0`.
const CAMERA_PREFIX: &str = "/dev/video";

/// Take one reading of everything the watcher compares.
///
/// `scan_cameras` gates the one reading that is not nearly free. See
/// [`cameras`]. A tick that skips it reports `None` rather than an empty list,
/// so the watcher knows the difference between "nothing has the camera" and
/// "nobody looked".
#[must_use]
pub fn observe(state_dir: &Path, scan_cameras: bool) -> Observed {
    let snapshot = cache::load(&cache::path(state_dir))
        .filter(|snapshot| !cache::is_stale(snapshot, probe::now_secs()));

    Observed {
        snapshot,
        battery: probe::battery(),
        cameras: scan_cameras.then(cameras),
    }
}

/// Whether an open file descriptor points at a camera.
///
/// Split out and taking a string so the rule is testable without a `/proc` that
/// happens to have a webcam open in it.
#[must_use]
pub fn is_camera_device(target: &str) -> bool {
    target.starts_with(CAMERA_PREFIX)
}

/// Every process currently holding a camera device open.
///
/// Walks `/proc/<pid>/fd`, which is the only way to ask this question: V4L2
/// exposes no "in use" flag anywhere in `/sys`, and the alternatives all fork.
///
/// This is the expensive reading, and by a margin that justifies the watcher
/// rate-limiting it rather than taking it every tick. Measured with divan on a
/// desktop session (`cargo bench`, `benches/observe.rs`): this walk runs about
/// 15 ms, where the rest of a tick, the snapshot file plus the battery out of
/// sysfs, is about 89 µs. Roughly a hundred and seventy times the cost of
/// everything around it.
#[must_use]
pub fn cameras() -> Vec<Camera> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };

    let mut found: Vec<String> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| is_process_dir(path))
        .filter(|path| holds_camera(path))
        .filter_map(|path| process_name(&path))
        .collect();

    // Sorted for two reasons at once. /proc enumerates in whatever order the
    // kernel likes, and a notification whose wording depended on that would
    // read differently run to run; and sorting is what makes the dedup below a
    // linear pass rather than the quadratic `contains` check it replaced.
    //
    // One row per program, not per process: a browser with three content
    // processes on the camera is still one thing using the camera.
    found.sort_unstable();
    found.dedup();

    found
        .into_iter()
        .map(|process| Camera { process })
        .collect()
}

/// Whether a `/proc` entry is a process rather than one of the pseudo-files
/// alongside them (`/proc/meminfo`, `/proc/self`, …).
fn is_process_dir(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.bytes().all(|byte| byte.is_ascii_digit()))
}

/// Whether any of a process's open descriptors points at a camera.
///
/// A process belonging to another user answers `EACCES`, which reads here as
/// "no", the right answer anyway, since a notification about someone else's
/// session would be noise.
fn holds_camera(proc_dir: &Path) -> bool {
    std::fs::read_dir(proc_dir.join("fd")).is_ok_and(|descriptors| {
        descriptors.flatten().any(|descriptor| {
            std::fs::read_link(descriptor.path())
                .is_ok_and(|target| target.to_str().is_some_and(is_camera_device))
        })
    })
}

/// The program name behind a `/proc/<pid>` directory.
fn process_name(proc_dir: &Path) -> Option<String> {
    let name = std::fs::read_to_string(proc_dir.join("comm")).ok()?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    Some(name.to_string())
}
