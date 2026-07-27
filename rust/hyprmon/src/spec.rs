//! Wire model: `hyprctl monitors -j` parsing and the monitor spec we emit
//! back. Only the fields the planner needs are modelled; everything else in
//! the JSON is dropped via `serde(default)`.

use serde::{Deserialize, Serialize};

/// One entry of `hyprctl monitors -j`. Field names mirror Hyprland's JSON
/// (camelCase) so the raw payload deserializes directly. `refreshRate` is in
/// Hz; `availableModes` is optional so synthetic test fixtures can omit it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Monitor {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    #[serde(rename = "refreshRate")]
    pub refresh_rate: f64,
    #[serde(default, rename = "physicalWidth")]
    pub physical_width: u32,
    #[serde(default, rename = "physicalHeight")]
    pub physical_height: u32,
    #[serde(default, rename = "currentFormat")]
    pub current_format: String,
    #[serde(default)]
    pub make: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub serial: String,
    #[serde(default)]
    pub transform: u8,
    #[serde(default)]
    pub vrr: bool,
    #[serde(default, rename = "availableModes")]
    pub available_modes: Vec<String>,
}

/// One emitted monitor spec. `position` is the absolute top-left in pixels
/// (`XxY`); `scale` is Hyprland's monitor scale (float, rendered without a
/// trailing `.0` when integral, matching the conf style). `vrr` is rendered
/// as the trailing `vrrleft`/`vrrright`/`vrrauto` token for the legacy
/// `hyprctl keyword monitor` form, and as an integer `vrr` field for the Lua
/// `hl.monitor` form used by the non-legacy parser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MonitorSpec {
    pub name: String,
    pub resolution: String,
    pub position: String,
    pub scale: String,
    pub transform: Option<u8>,
    pub vrr: Option<String>,
}

impl MonitorSpec {
    /// Render as the comma-joined argument to the legacy `hyprctl keyword
    /// monitor` command. e.g. `DP-1,1920x1080@240,0x0,1,vrrleft` (no `vrr*`
    /// token when [`None`](Self::vrr)). Kept for tests and logging.
    #[must_use]
    pub fn render(&self) -> String {
        let mut parts = vec![
            self.name.clone(),
            self.resolution.clone(),
            self.position.clone(),
            self.scale.clone(),
        ];
        if let Some(t) = self.transform {
            parts.push(t.to_string());
        }
        if let Some(v) = &self.vrr {
            parts.push(v.clone());
        }
        parts.join(",")
    }

    /// Render as a Lua table argument for `hyprctl eval 'hl.monitor({...})'`.
    /// Hyprland 0.55+ disables the legacy `hyprctl keyword monitor ...` IPC
    /// when the Lua parser is active, so the live runner uses this form.
    #[must_use]
    pub fn render_lua(&self) -> String {
        let mut fields = vec![
            format!("output={}", lua_string(&self.name)),
            format!("mode={}", lua_string(&self.resolution)),
            format!("position={}", lua_string(&self.position)),
            format!("scale={}", lua_number(&self.scale)),
        ];
        if let Some(t) = self.transform {
            fields.push(format!("transform={t}"));
        }
        if let Some(v) = &self.vrr {
            fields.push(format!("vrr={}", vrr_to_int(v)));
        }
        format!("hl.monitor({{{}}})", fields.join(", "))
    }
}

fn lua_string(s: &str) -> String {
    // Escape backslashes and double quotes, then wrap in double quotes.
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn lua_number(s: &str) -> String {
    // Accepts strings like "1" or "1.5"; invalid input falls back to itself so
    // Hyprland errors visibly instead of silently ignoring the value.
    s.parse::<f64>()
        .map_or_else(|_| s.to_string(), |n| format!("{n}"))
}

/// Map the legacy `vrr*` keyword token to the integer Hyprland's Lua
/// `hl.monitor` expects. The Lua field takes 0 off, 1 on, 2 always, 3
/// fullscreen; `vrrleft`/`vrrright`/`vrrauto` are the old per-display VRR
/// tokens and map to 1/2/3.
fn vrr_to_int(token: &str) -> u8 {
    match token {
        "vrrleft" => 1,
        "vrrright" => 2,
        "vrrauto" => 3,
        _ => 0,
    }
}
