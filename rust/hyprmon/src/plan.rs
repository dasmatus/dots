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
use crate::spec::{Monitor, MonitorSpec};

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
/// rule with `WxH` emits `WxH@R` where `R` is the highest refresh the monitor
/// advertises for that resolution (rounded up to an integer Hz); a rule with
/// `WxH@R` honours the authored resolution but rounds `R` up to an integer.
fn effective_resolution_string(m: &Matched, w: u32, h: u32) -> String {
    let base = match &m.rule.resolution {
        // Explicit `WxH@R`: honour the authored resolution, round the refresh
        // up to an integer Hz.
        Some(r) if r.contains('@') => {
            let (wh, rate) = r.split_once('@').unwrap_or((r, ""));
            match rate.parse::<f64>() {
                Ok(rate) if rate > 0.0 => format!("{}@{}", wh, round_up_refresh(rate)),
                _ => r.clone(),
            }
        }
        // Explicit `WxH` with no refresh: append the max supported refresh
        // (rounded up) so Hyprland doesn't fall back to a fractional default
        // like 59.95 Hz.
        Some(r) => match parse_wxh(r) {
            Some((rw, rh)) => match refresh_for(&m.monitor, rw, rh) {
                Some(rate) => format!("{r}@{rate}"),
                None => r.clone(),
            },
            // Non-`WxH` token (e.g. `highres`): defer to `preferred`.
            None => preferred_with_refresh(m),
        },
        // No explicit resolution → `preferred`, with the max supported refresh
        // (rounded up) as `@R`.
        None => preferred_with_refresh(m),
    };
    base.replace("__W__", &w.to_string())
        .replace("__H__", &h.to_string())
}

/// `preferred` with the max supported refresh (rounded up) as `@R`, or bare
/// `preferred` when no rate can be determined (no modes and no live rate).
fn preferred_with_refresh(m: &Matched) -> String {
    match refresh_for(&m.monitor, m.monitor.width, m.monitor.height) {
        Some(rate) => format!("preferred@{rate}"),
        None => "preferred".to_string(),
    }
}

/// Refresh rate (integer Hz, rounded up) to append to a `WxH` or `preferred`
/// resolution: the highest rate the monitor advertises for that resolution in
/// `availableModes`, falling back to the live `refreshRate` when no modes are
/// listed. The fallback is the NVIDIA workaround — the proprietary driver does
/// not populate `availableModes` over wlr-output-management the way KMS
/// drivers do, so without it a rule like `2560x1200` (no explicit refresh)
/// would land on Hyprland's fractional default (e.g. 59.95 Hz) instead of the
/// intended 60.
fn refresh_for(monitor: &Monitor, w: u32, h: u32) -> Option<i64> {
    max_refresh_at(&monitor.available_modes, w, h)
        .or_else(|| (monitor.refresh_rate > 0.0).then_some(monitor.refresh_rate))
        .map(round_up_refresh)
}

/// Highest refresh rate the monitor advertises for resolution `w×h`, parsed
/// from `availableModes` entries of the form `WxH@R`. `None` when no mode
/// matches (or when the driver reports no modes, as NVIDIA does).
fn max_refresh_at(modes: &[String], w: u32, h: u32) -> Option<f64> {
    modes
        .iter()
        .filter_map(|m| parse_mode(m))
        .filter(|&(mw, mh, _)| mw == w && mh == h)
        .map(|(_, _, rate)| rate)
        .max_by(f64::total_cmp)
}

/// `1920x1080@239.76` → `(1920, 1080, 239.76)`. `None` for malformed modes —
/// `availableModes` occasionally contains entries we don't model.
fn parse_mode(s: &str) -> Option<(u32, u32, f64)> {
    let (wh, rate) = s.split_once('@')?;
    let (w, h) = wh.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?, rate.parse().ok()?))
}

/// Round a refresh rate up to the next integer Hz. Monitors advertise
/// fractional rates (59.95, 119.98, 239.76) that Hyprland honours literally,
/// producing a sub-integer clock; ceiling snaps to the intended 60/120/240.
fn round_up_refresh(r: f64) -> i64 {
    r.ceil() as i64
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
#[must_use]
pub fn render_scale(s: f64) -> String {
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
