//! Pure parsers, one per source format.
//!
//! Nothing here opens a file or spawns a process; every function takes the text
//! a probe already read. That is what makes the awkward cases testable — a
//! machine with no active connection, a battery reporting charge instead of
//! energy, a muted sink, a localised `df` header — none of which can be staged
//! on the developer's own machine on demand.

use crate::model::{
    Backlight, Battery, BatteryState, Disk, Load, Memory, Network, NetworkKind, Service, Volume,
    Vpn,
};

/// Bytes in a kibibyte, the unit `/proc/meminfo` reports in.
const KIB: u64 = 1024;

/// `/proc/meminfo`.
///
/// Reads `MemTotal` and `MemAvailable`; see [`Memory`] for why availability
/// rather than free.
#[must_use]
pub fn meminfo(raw: &str) -> Option<Memory> {
    let field = |key: &str| {
        raw.lines()
            .find_map(|line| line.strip_prefix(key)?.trim().strip_suffix("kB"))
            .and_then(|value| value.trim().parse::<u64>().ok())
            .map(|kib| kib * KIB)
    };

    let total = field("MemTotal:")?;
    let available = field("MemAvailable:")?;
    Some(Memory {
        used: total.saturating_sub(available),
        total,
    })
}

/// `/proc/loadavg`.
#[must_use]
pub fn loadavg(raw: &str) -> Option<Load> {
    let mut fields = raw.split_whitespace();
    Some(Load {
        one: fields.next()?.parse().ok()?,
        five: fields.next()?.parse().ok()?,
        fifteen: fields.next()?.parse().ok()?,
    })
}

/// `/proc/uptime`, whose first field is seconds since boot as a float.
///
/// The fractional part is discarded by splitting the text rather than by
/// parsing to `f64` and truncating: an uptime in the tens of millions of
/// seconds is ordinary on a server, and this keeps the value exact instead of
/// routing it through a mantissa.
#[must_use]
pub fn uptime(raw: &str) -> Option<u64> {
    let field = raw.split_whitespace().next()?;
    let whole = field.split_once('.').map_or(field, |(whole, _)| whole);
    whole.parse().ok()
}

/// `brightness` over `max_brightness`.
#[must_use]
pub fn backlight(brightness: &str, max_brightness: &str) -> Option<Backlight> {
    let now: u64 = brightness.trim().parse().ok()?;
    let max: u64 = max_brightness.trim().parse().ok()?;
    Some(Backlight {
        percent: crate::model::percent_of(now, max),
    })
}

/// The four `/sys/class/power_supply/BAT*` files a battery row needs.
///
/// `charge`/`current` (µAh, µA) and `energy`/`power` (µWh, µW) are alternative
/// spellings of the same thing and a given machine exposes exactly one pair, so
/// the caller passes whichever it found and the remaining-time division works
/// out identically either way — the units cancel.
#[derive(Debug, Clone, Copy, Default)]
pub struct BatteryReading<'a> {
    pub name: &'a str,
    pub capacity: &'a str,
    pub status: &'a str,
    /// `charge_now` or `energy_now`.
    pub now: Option<&'a str>,
    /// `charge_full` or `energy_full`.
    pub full: Option<&'a str>,
    /// `current_now` or `power_now`.
    pub rate: Option<&'a str>,
}

/// Build a [`Battery`] from raw sysfs text.
#[must_use]
pub fn battery(reading: BatteryReading<'_>) -> Option<Battery> {
    // capacity is documented as 0-100, but firmware overshoots it often enough
    // that clamping is cheaper than a percentage bar rendering past its track.
    let percent: u8 = reading.capacity.trim().parse::<u8>().ok()?.min(100);
    let state = BatteryState::from_sysfs(reading.status);

    let parse = |value: Option<&str>| value.and_then(|v| v.trim().parse::<u64>().ok());
    let now = parse(reading.now);
    let full = parse(reading.full);
    let rate = parse(reading.rate).filter(|rate| *rate > 0);

    let seconds_remaining = match (state, now, full, rate) {
        (BatteryState::Discharging, Some(now), _, Some(rate)) => Some(now * 3600 / rate),
        (BatteryState::Charging, Some(now), Some(full), Some(rate)) => {
            Some(full.saturating_sub(now) * 3600 / rate)
        }
        _ => None,
    };

    Some(Battery {
        name: reading.name.to_string(),
        percent,
        state,
        seconds_remaining,
    })
}

/// `wpctl get-volume @DEFAULT_AUDIO_SINK@`.
///
/// The output is `Volume: 0.35` with an optional ` [MUTED]` suffix. The value
/// is a ratio, and `wpctl` will report above 1.0 for software boost, so the
/// percentage is deliberately not clamped.
#[must_use]
pub fn wpctl_volume(raw: &str) -> Option<Volume> {
    let line = raw.lines().find(|line| line.contains("Volume:"))?;
    let muted = line.contains("[MUTED]");
    let value = line.split_whitespace().nth(1)?;
    let ratio: f64 = value.parse().ok()?;
    if !ratio.is_finite() || ratio < 0.0 {
        return None;
    }
    let scaled = (ratio * 100.0).round();
    // Range-checked before the cast rather than after: `as` would wrap a
    // nonsense reading into a plausible-looking one.
    if scaled > f64::from(u16::MAX) {
        return None;
    }
    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "checked non-negative and within u16 immediately above"
    )]
    Some(Volume {
        percent: scaled as u16,
        muted,
    })
}

/// `nmcli -t -f NAME,DEVICE,TYPE connection show --active`.
///
/// Lifted from waybar's `dots-network-pill`, whose rule this reproduces
/// exactly: the first wireless connection wins outright, otherwise the first
/// wired one. Everything else — `wireguard`, `tun`, `loopback`, the Proton
/// kill-switch `dummy` — is skipped, because waybar's built-in module picked
/// the kill-switch interface and leaked its IP into the bar, which is the bug
/// that pill existed to fix.
#[must_use]
pub fn nmcli_active(raw: &str) -> Option<Network> {
    let mut ethernet = None;

    for line in raw.lines() {
        let mut fields = line.split(':');
        let (Some(name), Some(device), Some(kind)) = (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };

        match kind {
            "802-11-wireless" => {
                return Some(Network {
                    kind: NetworkKind::Wifi,
                    name: name.to_string(),
                    device: device.to_string(),
                })
            }
            "802-3-ethernet" if ethernet.is_none() => {
                ethernet = Some(Network {
                    kind: NetworkKind::Ethernet,
                    name: name.to_string(),
                    device: device.to_string(),
                });
            }
            _ => {}
        }
    }

    ethernet
}

/// The Proton VPN server name for the tunnel interface, from the same
/// `nmcli` output [`nmcli_active`] reads.
///
/// Presence of the interface is what proves the connection (the GTK app pins
/// it to `proton0` for both its `WireGuard` and `OpenVPN` backends); this only
/// supplies the label. `interface` is a parameter rather than a constant so the
/// test can drive it without a tunnel up.
#[must_use]
pub fn nmcli_vpn_server(raw: &str, interface: &str) -> Option<String> {
    raw.lines().find_map(|line| {
        let mut fields = line.split(':');
        let name = fields.next()?;
        (fields.next()? == interface).then(|| name.to_string())
    })
}

/// `systemctl --user is-active <unit>`.
///
/// The exit status is the real contract and the word is the readable one; this
/// takes the word, since a probe that captured output has it either way.
#[must_use]
pub fn systemctl_is_active(raw: &str) -> Service {
    Service {
        active: raw.trim() == "active",
    }
}

/// `df -B1 --output=used,size,pcent <path>`.
///
/// Fields are taken by position and the first line is dropped unconditionally.
/// The header is localised — on a German system it reads
/// `Benutzt 1B-Blöcke Verw%` — so matching on its text works on the developer's
/// machine and nowhere else.
#[must_use]
pub fn df(raw: &str, path: &str) -> Option<Disk> {
    let row = raw.lines().nth(1)?;
    let mut fields = row.split_whitespace();
    let used: u64 = fields.next()?.parse().ok()?;
    let total: u64 = fields.next()?.parse().ok()?;
    Some(Disk {
        path: path.to_string(),
        used,
        total,
    })
}

/// Build the VPN reading from interface presence plus an optional server name.
#[must_use]
pub fn vpn(interface_present: bool, server: Option<String>) -> Vpn {
    Vpn {
        connected: interface_present,
        server: if interface_present { server } else { None },
    }
}
