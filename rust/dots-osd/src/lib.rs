//! On-screen feedback for a desktop that has no bar.
//!
//! Everything this machine can tell you about itself lives inside beamenu now,
//! which is excellent for asking a question and useless for being told an
//! answer. The volume moved; the VPN dropped; `/home` is at 94%. None of that
//! survives being one keystroke away. You have to already suspect it to go
//! looking. This crate is the other half: the readings that should come to you.
//!
//! Two halves, split by who started it.
//!
//! [`control`] is what a keybind calls. It moves the thing and reports what
//! resulted, in one process, so pressing volume-up puts a bar on screen rather
//! than leaving you to guess whether the key registered.
//!
//! [`watch`] is what notices. It compares one [`watch::Observed`] against the
//! last and answers with the notifications that reading earned, nothing at all
//! on most ticks, which is the point. It is pure, so every threshold and every
//! hysteresis rule is tested against two structs rather than against a disk
//! someone had to fill up first.
//!
//! [`observe`] takes the readings [`watch`] compares, and [`notify`] puts a
//! [`model::Notification`] on the screen. Both are the thin impure edges;
//! neither decides anything.
//!
//! Failures are [`error::Error`], a concrete enum rather than a boxed dynamic
//! error, because the only caller is a keybind or a systemd unit and neither
//! has a terminal to read a message from. Each variant carries what a person
//! would need to act on it. For the shell-outs, that means the child's
//! exit status and its stderr rather than a summary of them.

pub mod control;
pub mod error;
pub mod model;
pub mod notify;
pub mod observe;
pub mod watch;

pub use error::{Error, Result};
