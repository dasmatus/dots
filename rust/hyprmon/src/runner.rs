//! The live runner: read `hyprctl monitors -j`, plan, and apply via
//! `hyprctl eval 'hl.monitor({...})'`. Shell access is behind a [`HyprCtl`]
//! trait so the apply orchestrator is unit-testable without a compositor (the
//! test backend records the Lua call, mirroring `wallpaper-tui`'s
//! `AwwwBackend`).
//!
//! Note: Hyprland 0.55+ disables the legacy `hyprctl keyword monitor ...` IPC
//! when the Lua ("non-legacy") parser is active. The old command exits 0 but
//! prints an error and changes nothing, so `apply` uses `hyprctl eval` with an
//! `hl.monitor({...})` Lua expression instead.

use std::process::{Command, Stdio};

use crate::matcher::match_monitors;
use crate::plan::plan;
use crate::rules::Rules;
use crate::spec::{Monitor, MonitorSpec};

/// Indirection over the two `hyprctl` callsites (`monitors -j` and `eval`)
/// so the apply orchestrator is unit-testable without a live compositor.
pub trait HyprCtl {
    /// Run `hyprctl monitors -j` and return its stdout (JSON).
    fn monitors_json(&self) -> Result<String, String>;
    /// Run `hyprctl eval <lua_expression>` and return its trimmed stdout.
    fn eval(&self, lua: &str) -> Result<String, String>;
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

    fn eval(&self, lua: &str) -> Result<String, String> {
        let out = Command::new("hyprctl")
            .args(["eval", lua])
            .stderr(Stdio::inherit())
            .output()
            .map_err(|e| format!("spawn hyprctl eval: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "hyprctl eval exited {}",
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
/// one `hyprctl eval 'hl.monitor({...})'` per spec. Returns the specs it
/// applied (for logging/tests). Empty match list is a no-op (leaves
/// Hyprland's auto-detect alone) rather than disabling every monitor.
pub fn apply(ctl: &impl HyprCtl, rules: &Rules) -> Result<Vec<MonitorSpec>, String> {
    let json = ctl.monitors_json()?;
    let monitors = parse_monitors(&json)?;
    let matched = match_monitors(&monitors, rules);
    let specs = plan(&matched);
    for s in &specs {
        ctl.eval(&s.render_lua())?;
    }
    Ok(specs)
}
