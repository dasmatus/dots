//! Two read-only modules salvaged out of `dots-sandbox` when the bespoke
//! per-app sandbox was retired for Flatpak + AppArmor (see git history).
//! Neither ever had anything to do with launching an app, so both outlived
//! the crate they were born in.
//!
//! `report` is the collector for the privacy and hardware-security
//! dashboard: read-only and unprivileged throughout, it gathers what
//! recently touched a sensor and how hard this machine is to attack into
//! one JSON document for `qml/settings/pages/security.qml` to render.
//!
//! `triage` classifies AppArmor denial records into allow/block proposals
//! via a deterministic heuristic table, with a `sanitize_query` gate for an
//! optional LLM-assist layer. It is what turns a complain-mode denial log
//! into the rules a per-app profile needs before it can move to enforce.
//!
//! One crate, two subcommands, rather than two crates: they share a build
//! (`cargo fmt`/`clippy`/`test` in one place), neither depends on the
//! other, and splitting them would only double the Cargo.toml/flake
//! plumbing for two files that already live at the opposite ends of one
//! security story — what state the machine is in, and what would need to
//! change to confine it further.

pub mod report;
pub mod triage;
