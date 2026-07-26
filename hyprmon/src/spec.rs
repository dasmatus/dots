//! Wire model: `hyprctl monitors -j` parsing and the `monitor` keyword spec
//! we emit back. Only the fields the planner needs are modelled; everything
//! else in the JSON is dropped via `serde(default)`.

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

/// One emitted `hyprctl keyword monitor …` spec. `position` is the absolute
/// top-left in pixels (`XxY`); `scale` is Hyprland's monitor scale (float, but
/// rendered without a trailing `.0` when integral, matching the conf style).
/// `vrr` is rendered as the trailing `vrrleft`/`vrrright`/`vrrauto` token,
/// omitted when `None` so the keyword stays minimal for non-VRR panels.
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
    /// Render as the comma-joined argument to `hyprctl keyword monitor`.
    /// e.g. `DP-1,1920x1080@240,0x0,1,vrrleft` (no `vrr*` token when
    /// [`None`](Self::vrr)).
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
}
