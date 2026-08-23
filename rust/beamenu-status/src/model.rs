//! What a system status *is*, independent of where it was read from.
//!
//! Every type here is plain data with no I/O, so [`crate::parse`] can build one
//! from a fixture string and the tests never touch the machine. The split
//! matters more than usual: half these readings come from files that only exist
//! on a laptop, and the other half from commands that only answer inside a
//! logged-in session.

use serde::{Deserialize, Serialize};

/// Whether a battery is filling or draining.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BatteryState {
    Charging,
    Discharging,
    Full,
    /// `status` said something outside the set above, which sysfs is entitled
    /// to do (`Not charging` on a conservation-mode `ThinkPad`, for one).
    Unknown,
}

impl BatteryState {
    /// The sysfs `status` spelling, matched case-insensitively.
    #[must_use]
    pub fn from_sysfs(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "charging" => Self::Charging,
            "discharging" => Self::Discharging,
            "full" => Self::Full,
            _ => Self::Unknown,
        }
    }

    /// A word for the row's subtitle.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Charging => "charging",
            Self::Discharging => "on battery",
            Self::Full => "full",
            Self::Unknown => "unknown",
        }
    }
}

/// A battery, as far as `/sys/class/power_supply` will say.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Battery {
    /// Which supply this came from, e.g. `BAT0` or `BAT1`.
    pub name: String,
    pub percent: u8,
    pub state: BatteryState,
    /// Seconds until full or empty, when the kernel gave enough to derive it.
    ///
    /// Absent whenever the current reads zero, which it does for several
    /// seconds after a charger is plugged in and permanently on some
    /// firmware. An absent estimate is honest; a zero one is a lie.
    pub seconds_remaining: Option<u64>,
}

/// Screen brightness, as a percentage of the panel's maximum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Backlight {
    pub percent: u8,
}

/// An audio sink or source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Volume {
    /// May exceed 100: `wpctl` reports software boost as a value above 1.0.
    pub percent: u16,
    pub muted: bool,
}

/// RAM, in bytes.
///
/// `used` is derived from `MemAvailable` rather than `MemFree`, because
/// reclaimable page cache is not memory you have lost — reporting it as used
/// is what makes naive readouts claim a healthy machine is nearly full.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Memory {
    pub used: u64,
    pub total: u64,
}

impl Memory {
    #[must_use]
    pub fn percent(self) -> u8 {
        percent_of(self.used, self.total)
    }
}

/// Load average over the usual three windows.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Load {
    pub one: f64,
    pub five: f64,
    pub fifteen: f64,
}

/// One filesystem's occupancy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Disk {
    /// The path that was asked about, not the mount point it resolved to.
    pub path: String,
    pub used: u64,
    pub total: u64,
}

impl Disk {
    #[must_use]
    pub fn percent(&self) -> u8 {
        percent_of(self.used, self.total)
    }
}

/// How the machine is on the network.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NetworkKind {
    Wifi,
    Ethernet,
}

/// The active connection, ignoring tunnels.
///
/// VPN, tunnel and kill-switch connections are deliberately excluded upstream
/// in [`crate::parse::nmcli_active`]; this is the connection a person means
/// when they ask what network they are on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Network {
    pub kind: NetworkKind,
    /// The `NetworkManager` connection id — an SSID for Wi-Fi, a profile name
    /// for wired.
    pub name: String,
    pub device: String,
}

/// Proton VPN, keyed on its fixed tunnel interface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Vpn {
    pub connected: bool,
    /// The server name, when connected and `NetworkManager` knew it.
    pub server: Option<String>,
}

/// A systemd unit's liveness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Service {
    pub active: bool,
}

/// Everything the launcher cannot afford to read for itself.
///
/// Each field is `Option` because a probe failing is ordinary: `wpctl` is
/// absent outside a `PipeWire` session, `nmcli` outside `NetworkManager`, and a
/// desktop has no battery. A missing reading shows as a missing row, never as
/// a zero.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    /// Unix seconds at capture, so a reader can tell a stale file from a
    /// current one instead of trusting whatever it finds.
    #[serde(default)]
    pub captured_at: u64,
    #[serde(default)]
    pub volume: Option<Volume>,
    #[serde(default)]
    pub microphone: Option<Volume>,
    #[serde(default)]
    pub network: Option<Network>,
    #[serde(default)]
    pub vpn: Option<Vpn>,
    #[serde(default)]
    pub mail_bridge: Option<Service>,
    #[serde(default)]
    pub disks: Vec<Disk>,
}

/// Readings cheap enough to take on the spot, every keystroke.
///
/// Kept apart from [`Snapshot`] because the distinction is the whole design:
/// these come from `/proc` and `/sys` in microseconds, so they are always
/// current and never cached.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Live {
    pub battery: Option<Battery>,
    pub backlight: Option<Backlight>,
    pub memory: Option<Memory>,
    pub load: Option<Load>,
    pub uptime_seconds: Option<u64>,
    pub kernel: Option<String>,
    /// Hottest thermal zone in millidegrees Celsius.
    pub temperature_millicelsius: Option<i64>,
}

/// `used / total` as a rounded percentage, saturating rather than dividing by
/// zero when a filesystem or a memory total reads as empty.
///
/// Integer arithmetic in `u128`, not floating point. Byte counts reach the
/// hundreds of billions, and multiplying one by 100 in `u64` is within an order
/// of magnitude of overflow on a large enough array — while `f64` would start
/// losing precision above 2^53 bytes. `u128` costs nothing here and is exact.
#[must_use]
pub fn percent_of(used: u64, total: u64) -> u8 {
    if total == 0 {
        return 0;
    }
    let used = u128::from(used);
    let total = u128::from(total);
    // Add half the divisor before dividing: integer division truncates, and a
    // disk at 29.6% should read 30, not 29.
    let percent = (used * 100 + total / 2) / total;
    u8::try_from(percent.min(100)).unwrap_or(100)
}
