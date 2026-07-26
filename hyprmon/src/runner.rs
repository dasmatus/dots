//! The live runner: read `hyprctl monitors -j`, plan, and apply via
//! `hyprctl keyword monitor …`. Shell access is behind a [`HyprCtl`] trait so
//! the orchestrator is unit-testable without a compositor (the test backend
//! records argv, mirroring `wallpaper-tui`'s `AwwwBackend`).

use std::process::{Command, Stdio};

use crate::matcher::match_monitors;
use crate::plan::plan;
use crate::rules::Rules;
use crate::spec::{Monitor, MonitorSpec};

/// Indirection over the two `hyprctl` callsites (`monitors -j` and `keyword`)
/// so the apply orchestrator is unit-testable without a live compositor.
pub trait HyprCtl {
    /// Run `hyprctl monitors -j` and return its stdout (JSON).
    fn monitors_json(&self) -> Result<String, String>;
    /// Run `hyprctl keyword monitor <spec>` and return its trimmed stdout.
    fn keyword(&self, spec: &str) -> Result<String, String>;
}

/// Live backend that shells out to `hyprctl`.
pub struct LiveHyprCtl;

impl HyprCtl for LiveHyprCtl {
    fn monitors_json(&self) -> Result<String, String> {
        let out = Command::new("hyprctl")
            .args(["monitors", "-j"])
            .stderr(Stdio::null())
            .output()
            .map_err(|e| format!("spawn hyprctl monitors -j: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "hyprctl monitors -j exited {}",
                out.status.code().unwrap_or(-1)
            ));
        }
        String::from_utf8(out.stdout).map_err(|e| format!("non-utf8 stdout: {e}"))
    }

    fn keyword(&self, spec: &str) -> Result<String, String> {
        let out = Command::new("hyprctl")
            .args(["keyword", "monitor", spec])
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| format!("spawn hyprctl keyword: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "hyprctl keyword monitor exited {}",
                out.status.code().unwrap_or(-1)
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }
}

/// Read `hyprctl monitors -j` and parse it. Pure-ish helper shared by the
/// live runner and tests that want to feed a fixture string through the same
/// parser; the [`HyprCtl`] trait isn't needed here because the JSON is
/// already in hand.
pub fn parse_monitors(json: &str) -> Result<Vec<Monitor>, String> {
    serde_json::from_str(json).map_err(|e| format!("parse monitors -j: {e}"))
}

/// Full apply pipeline: fetch monitors → match against `rules` → plan → emit
/// one `hyprctl keyword monitor` per spec. Returns the specs it applied (for
/// logging/tests). Empty match list is a no-op (leaves Hyprland's auto-detect
/// alone) rather than disabling every monitor.
pub fn apply(ctl: &impl HyprCtl, rules: &Rules) -> Result<Vec<MonitorSpec>, String> {
    let json = ctl.monitors_json()?;
    let monitors = parse_monitors(&json)?;
    let matched = match_monitors(&monitors, rules);
    let specs = plan(&matched);
    for s in &specs {
        ctl.keyword(&s.render())?;
    }
    Ok(specs)
}
