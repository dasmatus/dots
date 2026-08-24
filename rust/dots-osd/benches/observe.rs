//! What the watcher's readings actually cost.
//!
//! Here to check one design decision rather than to chase a number. The watcher
//! scans for cameras on one tick in five, and that rate-limiting only earns its
//! complexity if the scan is genuinely dearer than everything around it. It
//! walks `/proc/<pid>/fd` for every process on the machine, which *sounds*
//! expensive but sounds are not measurements.
//!
//! Both benchmarks read the live machine, so the absolute numbers move with how
//! many processes happen to be running. The ratio between them is the part
//! worth reading.

use dots_osd::observe;
use dots_osd::watch::{Camera, Observed};

fn main() {
    divan::main();
}

/// The `/proc` walk: one `readdir` per process, one `readlink` per descriptor.
#[divan::bench]
fn cameras() -> Vec<Camera> {
    observe::cameras()
}

/// A tick that skips the camera scan: read the snapshot file, read the battery
/// out of sysfs. This is what four ticks in five cost.
#[divan::bench]
fn observe_without_cameras() -> Observed {
    observe::observe(&beamenu_status::cache::state_dir(), false)
}

/// A tick that includes it. The gap between this and the one above is what the
/// rate-limiting is buying.
#[divan::bench]
fn observe_with_cameras() -> Observed {
    observe::observe(&beamenu_status::cache::state_dir(), true)
}
