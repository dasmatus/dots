//! `hyprmon` — declarative multi-monitor auto-detection and setup for
//! Hyprland. The binary (`main.rs`) is a thin `hyprctl` wrapper; everything
//! testable lives here and is exercised by the integration tests in `tests/`.
//!
//! Pipeline: parse `hyprctl monitors -j` → match each monitor against a
//! JSON ruleset → plan a horizontal layout (left-to-right, ordered by rule
//! priority) → emit one `hyprctl keyword monitor <spec>` per output. Pure
//! functions front-to-back so the planner is unit-testable without a
//! compositor; only [`runner::apply`] shells out.

pub mod matcher;
pub mod overrides;
pub mod plan;
pub mod rules;
pub mod runner;
pub mod spec;
pub mod tui;
pub mod watch;

pub use matcher::match_monitors;
pub use overrides::{apply_overrides, match_override, OverrideEntry, Overrides};
pub use plan::plan;
pub use rules::{Rules, Vrr};
pub use runner::{apply, apply_with};
pub use spec::{Monitor, MonitorSpec};
