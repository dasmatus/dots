//! The layout planner. Turns a list of [`Matched`] monitors into a list of
//! [`MonitorSpec`]s with absolute positions, applying each rule's
//! resolution/scale/transform/vrr and laying monitors out left-to-right in
//! rule order (so the ruleset author controls the physical arrangement by
//! ordering rules — first rule = leftmost monitor).
//!
//! Position policy: a rule with an explicit `position` pins that monitor
//! absolutely and resets the running x-cursor to that monitor's right edge
//! (so a later rule with no `position` continues to its right). A rule with
//! no `position` is placed at the current x-cursor, vertically aligned to
//! `y=0`. This mirrors how a hand-written `monitor=` block chain behaves.

use crate::matcher::Matched;
use crate::rules::Vrr;
use crate::spec::MonitorSpec;

/// Plan a horizontal layout for the matched monitors. Returns one
/// [`MonitorSpec`] per match, in the same order as `matched`. Empty input is
/// a no-op (the runner then leaves Hyprland's auto-detect in place).
#[must_use]
pub fn plan(matched: &[Matched]) -> Vec<MonitorSpec> {
    let mut specs = Vec::with_capacity(matched.len());
    let mut x = 0_i64;
    for m in matched {
        let (w, h) = effective_resolution(m);
        let pos = m.rule.position.clone().unwrap_or_else(|| format!("{x}x0"));
        if let Some((px, _py)) = parse_position(&pos) {
            x = px + i64::from(w);
        } else {
            x = x.saturating_add(i64::from(w));
        }
        specs.push(MonitorSpec {
            name: m.monitor.name.clone(),
            resolution: effective_resolution_string(m, w, h),
            position: pos,
            scale: render_scale(m.rule.scale),
            transform: m.rule.transform,
            vrr: effective_vrr(m).and_then(Vrr::token),
        });
    }
    specs
}

/// Resolve the pixel size used for layout math. The rule's `resolution`
/// (when present) wins; otherwise the monitor's live `width`/`height`.
fn effective_resolution(m: &Matched) -> (u32, u32) {
    if let Some(r) = &m.rule.resolution {
        if let Some((w, h)) = parse_wxh(r) {
            return (w, h);
        }
    }
    (m.monitor.width, m.monitor.height)
}

/// Render the `monitor` keyword's resolution field. A rule with no
/// `resolution` emits `preferred` (Hyprland auto-picks the highest mode); a
/// rule with `WxH` emits `WxH`; a rule with `WxH@R` is passed through verbatim
/// (Hyprland accepts the `@R` refresh suffix).
fn effective_resolution_string(m: &Matched, w: u32, h: u32) -> String {
    match &m.rule.resolution {
        Some(r) if r.contains('@') || parse_wxh(r).is_some() => r.clone(),
        _ => {
            // No explicit resolution → `preferred`, optionally with the live
            // refresh rate as `@R` when the monitor reports a nonzero one.
            if m.monitor.refresh_rate > 0.0 {
                format!("preferred@{}", trim_refresh(m.monitor.refresh_rate))
            } else {
                "preferred".to_string()
            }
        }
    }
    .replace("__W__", &w.to_string())
    .replace("__H__", &h.to_string())
}

/// VRR token for the spec. The rule's `vrr` field is authoritative: when
/// it's `Off` we emit `None` (no `vrr*` token) even if the monitor already
/// reports `vrr: true` from a prior manual change, so re-running `hyprmon
/// apply` can turn VRR back off.
fn effective_vrr(m: &Matched) -> Option<Vrr> {
    (m.rule.vrr != Vrr::Off).then_some(m.rule.vrr)
}

/// `1.0` → `"1"`, `1.5` → `"1.5"`, `2.0` → `"2"`. Matches the integer-without-
/// trailing-zero style used in hand-written Hyprland configs.
fn render_scale(s: f64) -> String {
    if s.fract() == 0.0 {
        format!("{}", s as i64)
    } else {
        format!("{s}")
    }
}

/// `1920x1080` → `(1920, 1080)`; `1920x1080@240` → `(1920, 1080)` (refresh
/// stripped). Returns `None` for anything that isn't `WxH[@R]` with integer
/// W/H.
fn parse_wxh(s: &str) -> Option<(u32, u32)> {
    let base = s.split('@').next().unwrap_or(s);
    let (w, h) = base.split_once('x')?;
    let w: u32 = w.parse().ok()?;
    let h: u32 = h.parse().ok()?;
    Some((w, h))
}

/// `0x0` → `(0, 0)`; `1920x0` → `(1920, 0)`. Returns `None` for malformed
/// positions.
fn parse_position(s: &str) -> Option<(i64, i64)> {
    let (x, y) = s.split_once('x')?;
    Some((x.parse().ok()?, y.parse().ok()?))
}

/// Trim a refresh rate to a clean `240` / `119.98` rendering. Hyprland's
/// `monitor` keyword accepts a float after `@`, but `240.0` reads oddly in a
/// config, so integral rates drop the `.0`.
fn trim_refresh(r: f64) -> String {
    if r.fract() == 0.0 {
        format!("{}", r as i64)
    } else {
        format!("{r}")
    }
}
