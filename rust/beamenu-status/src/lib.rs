//! System status readouts, shared by the beamenu launcher and its dashboard.
//!
//! The launcher re-runs every provider synchronously on every keystroke, and it
//! renders *before* it blocks for the next key — so a slow reading does not
//! merely lag the list, it delays the character just typed from appearing. That
//! single fact shapes this crate into two halves:
//!
//! * [`probe::live`] reads `/proc` and `/sys` in microseconds. Safe inline,
//!   always current.
//! * [`probe::snapshot`] forks `wpctl`, `nmcli`, `systemctl` and `df` — tens of
//!   milliseconds each. It runs on the daemon's timer and leaves the result in
//!   [`cache`], where the launcher picks it up for the price of one small read.
//!
//! Both halves parse through [`parse`], which is pure. Nothing there opens a
//! file, so the awkward cases — no active connection, a muted sink, a battery
//! reporting charge rather than energy, a localised `df` header — are testable
//! without staging them on a real machine.

pub mod cache;
pub mod dashboard;
pub mod format;
pub mod model;
pub mod parse;
pub mod probe;
pub mod rpc;
