//! Provisional scaffold: exposes only the launcher/broker/grants half of
//! this crate built by task 9. The policy half (`policy`, `caps`, `argv`)
//! is being built in a parallel worktree and does not exist here yet —
//! `merge_stub` stands in for it until the two are merged; see that
//! module's doc comment.
pub mod broker;
pub mod grants;
pub mod launch;
pub mod merge_stub;
