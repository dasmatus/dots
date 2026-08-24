//! Turning readings into the short strings a launcher row can hold.
//!
//! Shared between the launcher's rows and the dashboard's markdown so the two
//! never disagree about what 96% or two and a half hours looks like.

use crate::model::{Battery, BatteryState, Disk, Memory, Network, NetworkKind, Volume, Vpn};

/// Binary unit steps, matching what `df` and every file manager show.
const UNITS: &[&str] = &["B", "KiB", "MiB", "GiB", "TiB", "PiB"];

/// A byte count as a short human string, e.g. `458 GiB`.
///
/// One decimal below 10 and none above, which is the resolution that fits a
/// launcher row without the number jittering in width as it changes.
#[must_use]
pub fn bytes(count: u64) -> String {
    if count < 1024 {
        return format!("{count} B");
    }

    // Pick the unit in integer space, so only the final display division is
    // floating point. Precision loss there is bounded by the format specifier
    // anyway: at most one decimal ever reaches the screen.
    let mut divisor: u64 = 1024;
    let mut unit = 1;
    while unit + 1 < UNITS.len() {
        match divisor.checked_mul(1024) {
            Some(next) if count >= next => {
                divisor = next;
                unit += 1;
            }
            _ => break,
        }
    }

    #[allow(
        clippy::cast_precision_loss,
        reason = "the result is rendered to at most one decimal place"
    )]
    let value = count as f64 / divisor as f64;

    if value < 10.0 {
        format!("{value:.1} {}", UNITS[unit])
    } else {
        format!("{value:.0} {}", UNITS[unit])
    }
}

/// A duration as `2h 14m`, or `47m` under an hour.
///
/// Days are spelled out past 24 hours, because an uptime row reading `412h` is
/// technically correct and useless.
#[must_use]
pub fn duration(seconds: u64) -> String {
    let minutes = seconds / 60;
    let hours = minutes / 60;
    let days = hours / 24;

    if days > 0 {
        format!("{days}d {}h", hours % 24)
    } else if hours > 0 {
        format!("{hours}h {}m", minutes % 60)
    } else {
        format!("{minutes}m")
    }
}

/// The value shown at the right of a battery row.
#[must_use]
pub fn battery_value(battery: &Battery) -> String {
    match battery.seconds_remaining {
        Some(remaining) if battery.state != BatteryState::Full => {
            format!("{}% · {}", battery.percent, duration(remaining))
        }
        _ => format!("{}%", battery.percent),
    }
}

/// The detail line under a battery row.
#[must_use]
pub fn battery_detail(battery: &Battery) -> String {
    match (battery.state, battery.seconds_remaining) {
        (BatteryState::Charging, Some(_)) => format!("{} · until full", battery.name),
        (BatteryState::Discharging, Some(_)) => format!("{} · remaining", battery.name),
        (state, _) => format!("{} · {}", battery.name, state.label()),
    }
}

/// The value shown at the right of a volume row.
#[must_use]
pub fn volume_value(volume: Volume) -> String {
    if volume.muted {
        format!("muted ({}%)", volume.percent)
    } else {
        format!("{}%", volume.percent)
    }
}

/// The value shown at the right of a memory row.
#[must_use]
pub fn memory_value(memory: Memory) -> String {
    format!("{}%", memory.percent())
}

/// The detail line under a memory row.
#[must_use]
pub fn memory_detail(memory: Memory) -> String {
    format!("{} of {} in use", bytes(memory.used), bytes(memory.total))
}

/// The value shown at the right of a disk row.
#[must_use]
pub fn disk_value(disk: &Disk) -> String {
    format!("{}%", disk.percent())
}

/// The detail line under a disk row.
#[must_use]
pub fn disk_detail(disk: &Disk) -> String {
    format!(
        "{} of {} used on {}",
        bytes(disk.used),
        bytes(disk.total),
        disk.path
    )
}

/// The value shown at the right of the network row.
#[must_use]
pub fn network_value(network: Option<&Network>) -> String {
    network.map_or_else(
        || "disconnected".to_string(),
        |network| network.name.clone(),
    )
}

/// The detail line under the network row.
#[must_use]
pub fn network_detail(network: Option<&Network>) -> String {
    match network {
        Some(network) => {
            let kind = match network.kind {
                NetworkKind::Wifi => "Wi-Fi",
                NetworkKind::Ethernet => "Wired",
            };
            format!("{kind} on {}", network.device)
        }
        None => "No active network connection".to_string(),
    }
}

/// The value shown at the right of the VPN row.
#[must_use]
pub fn vpn_value(vpn: &Vpn) -> String {
    match (&vpn.connected, &vpn.server) {
        (true, Some(server)) => server.clone(),
        (true, None) => "connected".to_string(),
        (false, _) => "off".to_string(),
    }
}

/// Celsius from the millidegrees every thermal zone reports.
///
/// Rounded in integer space. Half is added away from zero rather than towards
/// it, so a below-freezing zone rounds the same direction a positive one does.
#[must_use]
pub fn temperature(millicelsius: i64) -> String {
    let half = if millicelsius < 0 { -500 } else { 500 };
    format!("{}°C", (millicelsius + half) / 1000)
}

/// A fixed-width bar for the dashboard's markdown, since the canvas has no
/// gauge component to render into.
#[must_use]
pub fn bar(percent: u8, width: usize) -> String {
    let filled = usize::from(percent).min(100) * width / 100;
    let mut out = String::with_capacity(width);
    for slot in 0..width {
        out.push(if slot < filled { '█' } else { '░' });
    }
    out
}
