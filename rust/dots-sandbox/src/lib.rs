//! Library half of the per-app sandbox: the policy model (`policy`) and
//! the pure translation from a resolved policy into a `systemd-nspawn`/
//! `systemd-vmspawn` command line (`argv`). No process spawning lives
//! here — that, along with the broker, the prompter and the report
//! collector, is deliberately a later task's job, since the launch path
//! depends on a privilege question this crate's brief already resolved
//! for its own purposes (unprivileged, in the user session) but that a
//! real launcher still has to wire up end to end.

pub mod argv;
pub mod error;
pub mod policy;
