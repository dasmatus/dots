//! Filesystem existence checks. Backs the staleness sweep's "does the file
//! this fact cites still exist" test (design spec section 7: a `remembered`
//! fact must not outlive the file it came from).
use std::path::Path;

/// Whether `path` exists on the local filesystem, from the point of view of
/// the process making the call -- here, the running `postgres` backend.
/// Deliberately not exposed as `IMMUTABLE`: the filesystem is external
/// state that changes between calls with the same argument, unlike
/// `norm_hash_v1` or `slug_v1` in this crate.
pub fn path_exists(path: &str) -> bool {
    Path::new(path).exists()
}
