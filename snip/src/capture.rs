//! Orchestration of the grim → wl-copy → notify-send pipeline. The Tauri
//! command hides the overlay first so the compositor's blur is gone from the
//! framebuffer `grim` reads; a short race-guard delay covers the Wayland
//! surface-destroy async.

use crate::geometry::{format_grim_geometry, Rect};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::fs;
use std::process::{Command, Stdio};
use std::{env, fs::File};

/// One entry from `hyprctl monitors -j`.
#[derive(Debug, Deserialize)]
struct Monitor {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    focused: bool,
}

/// Return the focused monitor's `(x, y, width, height)`, falling back to the
/// first monitor if none is marked focused. `None` if `hyprctl` is unavailable
/// (e.g. not running under Hyprland) — callers fall back to the raw rect.
#[must_use]
pub fn focused_monitor() -> Option<(i32, i32, i32, i32)> {
    let out = Command::new("hyprctl")
        .args(["monitors", "-j"])
        .output()
        .ok()?;
    let monitors: Vec<Monitor> = serde_json::from_slice(&out.stdout).ok()?;
    let m = monitors
        .iter()
        .find(|m| m.focused)
        .or_else(|| monitors.first())?;
    Some((m.x, m.y, m.width, m.height))
}

/// Capture `geo` with grim to `~/Pictures/Screenshots/screenshot-<ts>.png`,
/// copy the file to the Wayland clipboard with `wl-copy`, and fire a dunst
/// notification with the saved path. The Tauri command logs any error and
/// exits regardless.
///
/// # Errors
///
/// Returns an error if `HOME` is unset, the screenshot directory cannot be
/// created, the `date` timestamp call fails, or `grim` exits non-zero.
pub fn run(geo: &Rect) -> Result<()> {
    let home = env::var("HOME").context("HOME is not set")?;
    let dir = format!("{home}/Pictures/Screenshots");
    fs::create_dir_all(&dir).with_context(|| format!("creating screenshot directory {dir}"))?;

    let ts = String::from_utf8(Command::new("date").arg("+%Y%m%d-%H%M%S").output()?.stdout)?
        .trim()
        .to_string();
    let path = format!("{dir}/screenshot-{ts}.png");

    let grim = Command::new("grim")
        .args(["-g", &format_grim_geometry(geo), "-t", "png", &path])
        .status()
        .context("spawning grim")?;
    if !grim.success() {
        bail!("grim exited with {grim}");
    }

    // Clipboard: pipe the saved file into wl-copy as image/png.
    let file = File::open(&path).with_context(|| format!("opening {path}"))?;
    let _ = Command::new("wl-copy")
        .args(["-t", "image/png"])
        .stdin(Stdio::from(file))
        .status();

    // Best-effort notification — never fatal.
    let _ = Command::new("notify-send")
        .args(["-i", &path, "Screenshot saved", &path])
        .status();

    Ok(())
}
