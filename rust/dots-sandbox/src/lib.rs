//! Per-app sandboxing, unprivileged and in the user session.
//!
//! The crate is in two halves that were built in parallel and meet here.
//!
//! The policy half is pure: `policy` models the layered capability document
//! (Nix-shipped defaults under user overrides) and `argv` translates a resolved
//! policy into a `systemd-nspawn` or `systemd-vmspawn` command line. Neither
//! touches the filesystem, the environment or the clock — everything arrives
//! through an injected context — which is what makes the whole
//! capability-to-command-line translation testable without a namespace, a VM or
//! root.
//!
//! The launch half does the work the pure half describes: `launch` spawns the
//! sandbox and forwards signals to it, `grants` adds and removes bind mounts on
//! a running machine through `machinectl --user`, and `broker` mediates a
//! capability request an app has not been granted.
//!
//! Everything runs as uid 1000. systemd 261 selects a `--user` scope for both
//! spawn binaries automatically, so no part of this needs root, setuid or file
//! capabilities. That is not merely convenient: system-scope `machinectl bind`
//! maps to the polkit action `org.freedesktop.machine1.manage-machines`, which
//! is `auth_admin_keep` — routing through it would mean an admin password
//! prompt on every single app launch.

pub mod argv;
pub mod broker;
pub mod error;
pub mod grants;
pub mod launch;
pub mod policy;
