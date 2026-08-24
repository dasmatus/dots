//! Turning "what the machine looks like now" into "what changed since last
//! time", with no I/O anywhere in it.
//!
//! [`advance`] is the whole watcher. It takes the state it remembered, one
//! fresh [`Observed`], and answers with the notifications that reading earned,
//! so every threshold, every hysteresis rule and every "say nothing on
//! startup" decision is testable by handing it two structs, on a machine with
//! no battery, no VPN and a disk that is not filling up.
//!
//! Two shapes of notification live here and they are treated differently.
//! *Events*, things like a network appearing, a VPN dropping, or a camera
//! switching on, are silent on the first observation, because a watcher
//! starting up has not witnessed a change, it has merely arrived.
//! *Conditions*, things like a disk already past 80% or a battery already at
//! 9%, are announced on the first observation, because logging in to a full
//! disk is exactly when you want to be told.
//!
//! Volume and mute are in the snapshot and deliberately not watched here, even
//! though they are the readings that change most often. They belong to
//! [`crate::control`], which announces them at the instant the key is pressed.
//! Watching them too would mean every keypress notified twice, once
//! immediately and once more when the poller caught up seconds later, and
//! there is no way from here to tell the keypress apart from anything else that
//! moved the slider.

use std::collections::HashMap;

use beamenu_status::format;
use beamenu_status::model::{Battery, BatteryState, Disk, Network, NetworkKind, Snapshot, Vpn};

use crate::model::{Notification, Urgency};

/// Occupancy at which a filesystem is worth mentioning.
const DISK_HIGH: u8 = 80;
/// Occupancy at which it is worth interrupting for.
const DISK_CRITICAL: u8 = 90;

/// Charge at which a battery is worth mentioning.
const BATTERY_LOW: u8 = 20;
/// Charge at which it is worth interrupting for.
const BATTERY_CRITICAL: u8 = 10;

/// How far a reading must fall back before it is allowed out of a band.
///
/// Without it, a filesystem hovering on exactly 80% would announce itself every
/// tick as the rounded percentage flickered either side of the line. Three
/// points is enough to absorb that and small enough that a real recovery still
/// registers.
const MARGIN: u8 = 3;

/// A process holding a camera device open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Camera {
    /// The process name, which is what a person recognises.
    pub process: String,
}

/// Everything one tick looked at.
///
/// Two different kinds of absence, and the distinction is load-bearing.
/// `snapshot` is `None` when the status poller has not written one, or wrote
/// one too old to trust. The watcher then reports nothing rather than reading
/// a frozen file as a world where nothing ever changes. `cameras` is `None`
/// when this tick did not go looking, which is most of them: an empty `Vec`
/// would mean "every camera stopped" and fire a notification saying so.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Observed {
    pub snapshot: Option<Snapshot>,
    pub battery: Option<Battery>,
    pub cameras: Option<Vec<Camera>>,
}

/// Which side of the thresholds a reading sits on.
///
/// Ordered so "worse than before" is a comparison rather than a match.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord)]
pub enum Band {
    #[default]
    Fine,
    Warn,
    Critical,
}

/// What the watcher carries between ticks.
///
/// Bands rather than raw percentages, because hysteresis is a function of the
/// band you were in: leaving a band needs a bigger move than entering it did,
/// and the previous percentage alone cannot express that.
#[derive(Debug, Clone, Default)]
pub struct State {
    /// False until a snapshot has been folded in.
    ///
    /// Deliberately not "has any tick happened". Those come apart, and getting
    /// them confused is a bug with teeth: the watcher can run for several ticks
    /// before the status poller writes its first file, because its unit is only
    /// ordered `After` that one rather than waiting for fresh output, and a
    /// `Restart=on-failure` lands the next first tick wherever it lands. A
    /// single "have I seen anything" flag would go true on one of those blind
    /// ticks while `network` was still `None`, and then read the genuinely
    /// first snapshot as a reconnection and announce a network that had been up
    /// the whole time.
    seen_snapshot: bool,
    /// False until a camera scan has been folded in. Separate again, and for
    /// the same reason squared: scans run on one tick in five, so most ticks
    /// carry no scan at all.
    seen_cameras: bool,
    network: Option<Network>,
    vpn: Option<Vpn>,
    mail_bridge: Option<bool>,
    disks: HashMap<String, Band>,
    /// How bad the charge is, which is not the same question as whether the
    /// charger is in: a battery at 8% and climbing is not low.
    charge: Band,
    battery: Option<BatteryState>,
    cameras: Vec<String>,
}

impl State {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

/// Which band `percent` falls in, given the band it was in before.
///
/// Rising crosses at the threshold; falling has to clear it by [`MARGIN`].
fn band(percent: u8, previous: Band, warn: u8, critical: u8) -> Band {
    let warn = if previous >= Band::Warn {
        warn.saturating_sub(MARGIN)
    } else {
        warn
    };
    let critical = if previous == Band::Critical {
        critical.saturating_sub(MARGIN)
    } else {
        critical
    };

    if percent >= critical {
        Band::Critical
    } else if percent >= warn {
        Band::Warn
    } else {
        Band::Fine
    }
}

/// Fold one observation into `state`, returning what it earned.
pub fn advance(state: &mut State, observed: &Observed) -> Vec<Notification> {
    let mut out = Vec::new();

    if let Some(snapshot) = &observed.snapshot {
        push_disks(&mut out, state, &snapshot.disks);
        if state.seen_snapshot {
            push_network(&mut out, state, snapshot.network.as_ref());
            push_vpn(&mut out, state, snapshot.vpn.as_ref());
            push_mail_bridge(&mut out, state, snapshot.mail_bridge.map(|s| s.active));
        }
        state.network.clone_from(&snapshot.network);
        state.vpn.clone_from(&snapshot.vpn);
        state.mail_bridge = snapshot.mail_bridge.map(|service| service.active);
        state.seen_snapshot = true;
    }

    push_battery(&mut out, state, observed.battery.as_ref());

    if let Some(cameras) = &observed.cameras {
        if state.seen_cameras {
            push_cameras(&mut out, state, cameras);
        }
        state.cameras = cameras
            .iter()
            .map(|camera| camera.process.clone())
            .collect();
        state.seen_cameras = true;
    }

    out
}

/// Filesystems crossing a threshold, in either direction.
fn push_disks(out: &mut Vec<Notification>, state: &mut State, disks: &[Disk]) {
    for disk in disks {
        let previous = state.disks.get(&disk.path).copied().unwrap_or_default();
        let current = band(disk.percent(), previous, DISK_HIGH, DISK_CRITICAL);
        state.disks.insert(disk.path.clone(), current);

        if current == previous {
            continue;
        }

        let free = disk.total.saturating_sub(disk.used);
        let summary = format!("Disk {}", disk.path);
        let new = |body: String| {
            Notification::new(
                disk_tag(&disk.path),
                "drive-harddisk-symbolic",
                summary.clone(),
            )
            .body(body)
            .value(u16::from(disk.percent()))
        };
        let notification = match current {
            Band::Critical => new(format!(
                "{}% full — only {} left",
                disk.percent(),
                format::bytes(free)
            ))
            .urgency(Urgency::Critical)
            .long(),
            Band::Warn => new(format!(
                "{}% full — {} left of {}",
                disk.percent(),
                format::bytes(free),
                format::bytes(disk.total)
            )),
            // Only worth saying when it is news, i.e. the filesystem had
            // previously been reported as filling up.
            Band::Fine => new(format!(
                "Back down to {}% — {} free",
                disk.percent(),
                format::bytes(free)
            ))
            .urgency(Urgency::Low),
        };
        out.push(notification);
    }
}

/// A stack tag per filesystem, so two of them crossing a threshold in the same
/// tick do not replace each other on screen.
///
/// The same split the launcher's status rows use for their ids
/// (`rust/beamenu/src/providers/status.rs`), and for the same reason: the tag
/// has to be `'static`, and these are the filesystems the poller reads.
fn disk_tag(path: &str) -> &'static str {
    match path {
        "/home" => "disk-home",
        "/nix/store" => "disk-nix",
        _ => "disk",
    }
}

/// The active connection appearing, changing or going away.
fn push_network(out: &mut Vec<Notification>, state: &State, current: Option<&Network>) {
    let previous = state.network.as_ref();
    match (previous, current) {
        (None, Some(network)) => out.push(
            Notification::new("network", network_icon(network), network_title(network))
                .body(format!("Connected to {}", network.name))
                .urgency(Urgency::Low),
        ),
        (Some(_), None) => out.push(
            Notification::new("network", "network-offline-symbolic", "Network")
                .body("Disconnected — no active connection"),
        ),
        (Some(before), Some(network)) if before.name != network.name => out.push(
            Notification::new("network", network_icon(network), network_title(network))
                .body(format!("Now on {}", network.name))
                .urgency(Urgency::Low),
        ),
        _ => {}
    }
}

fn network_title(network: &Network) -> &'static str {
    match network.kind {
        NetworkKind::Wifi => "Wi-Fi",
        NetworkKind::Ethernet => "Wired",
    }
}

fn network_icon(network: &Network) -> &'static str {
    match network.kind {
        NetworkKind::Wifi => "network-wireless-signal-excellent-symbolic",
        NetworkKind::Ethernet => "network-wired-symbolic",
    }
}

/// The tunnel coming up, moving, or dropping.
///
/// A drop is critical and the only one of the three that is: every other
/// notification here reports something you might like to know, and this one
/// reports that traffic you believed was tunnelled has stopped being.
fn push_vpn(out: &mut Vec<Notification>, state: &State, current: Option<&Vpn>) {
    let (Some(before), Some(vpn)) = (state.vpn.as_ref(), current) else {
        return;
    };

    if !before.connected && vpn.connected {
        let body = vpn.server.as_ref().map_or_else(
            || "Connected".to_string(),
            |server| format!("Connected — {server}"),
        );
        out.push(
            Notification::new("vpn", "network-vpn-symbolic", "VPN")
                .body(body)
                .urgency(Urgency::Low),
        );
    } else if before.connected && !vpn.connected {
        out.push(
            Notification::new("vpn", "network-vpn-disabled-symbolic", "VPN")
                .body("Disconnected — traffic is no longer tunnelled")
                .urgency(Urgency::Critical)
                .long(),
        );
    } else if vpn.connected && before.server != vpn.server {
        if let Some(server) = &vpn.server {
            out.push(
                Notification::new("vpn", "network-vpn-symbolic", "VPN")
                    .body(format!("Now on {server}"))
                    .urgency(Urgency::Low),
            );
        }
    }
}

/// The mail bridge stopping, which silently breaks every mail client on the
/// machine and is otherwise invisible.
fn push_mail_bridge(out: &mut Vec<Notification>, state: &State, current: Option<bool>) {
    let (Some(before), Some(active)) = (state.mail_bridge, current) else {
        return;
    };
    if before == active {
        return;
    }

    if active {
        out.push(
            Notification::new("mail-bridge", "mail-send-receive-symbolic", "Mail Bridge")
                .body("Running again")
                .urgency(Urgency::Low),
        );
    } else {
        out.push(
            Notification::new("mail-bridge", "mail-unread-symbolic", "Mail Bridge")
                .body("Stopped — mail will not sync until it is restarted"),
        );
    }
}

/// Charge thresholds while discharging, plus the charger going in and out.
fn push_battery(out: &mut Vec<Notification>, state: &mut State, battery: Option<&Battery>) {
    let Some(battery) = battery else {
        return;
    };

    let discharging = battery.state == BatteryState::Discharging;
    // Charging resets the band outright rather than easing out of it: a
    // battery on the charger is not low no matter what it reads, and clearing
    // the band is what lets unplugging at 15% warn again.
    let current = if discharging {
        band(
            // The bands are "how bad is it", so a charge percentage has to be
            // inverted before it can share [`band`] with an occupancy one.
            100u8.saturating_sub(battery.percent),
            state.charge,
            100 - BATTERY_LOW,
            100 - BATTERY_CRITICAL,
        )
    } else {
        Band::Fine
    };
    let previous = std::mem::replace(&mut state.charge, current);

    let was = state.battery.replace(battery.state);
    // No separate "have I seen a battery" flag: `was` is the previous reading,
    // so `is_some_and` already means both that there was one and that it
    // differs. A flag here would be a second way to say the same thing, and
    // two ways to say it is how the snapshot gate went wrong.
    if was.is_some_and(|before| before != battery.state) {
        push_charger(out, battery);
    }

    if current == previous || current == Band::Fine {
        return;
    }

    let remaining = battery
        .seconds_remaining
        .map_or_else(String::new, |seconds| {
            format!(" — about {} left", format::duration(seconds))
        });
    let notification = match current {
        Band::Critical => {
            Notification::new("battery", "battery-empty-symbolic", "Battery critical")
                .body(format!("{}%{remaining}", battery.percent))
                .urgency(Urgency::Critical)
                .long()
        }
        _ => Notification::new("battery", "battery-caution-symbolic", "Battery low")
            .body(format!("{}%{remaining}", battery.percent)),
    };
    out.push(notification.value(u16::from(battery.percent)));
}

/// The charger going in or out, which is the one battery event you can cause.
fn push_charger(out: &mut Vec<Notification>, battery: &Battery) {
    let (icon, body) = match battery.state {
        BatteryState::Charging => (
            "battery-good-charging-symbolic",
            format!("Charging — {}%", battery.percent),
        ),
        BatteryState::Discharging => (
            "battery-good-symbolic",
            format!("On battery — {}%", battery.percent),
        ),
        BatteryState::Full => ("battery-full-charged-symbolic", "Fully charged".to_string()),
        BatteryState::Unknown => return,
    };
    out.push(
        Notification::new("battery-power", icon, "Battery")
            .body(body)
            .urgency(Urgency::Low)
            .value(u16::from(battery.percent))
            .brief(),
    );
}

/// Something starting or stopping capture from a camera.
///
/// The whole point of the privacy half of this crate: without a bar there is
/// nothing on screen to tell you the webcam came on.
fn push_cameras(out: &mut Vec<Notification>, state: &State, cameras: &[Camera]) {
    let started: Vec<&str> = cameras
        .iter()
        .map(|camera| camera.process.as_str())
        .filter(|process| !state.cameras.iter().any(|before| before == process))
        .collect();

    if !started.is_empty() {
        out.push(
            Notification::new("camera", "camera-web-symbolic", "Camera in use")
                .body(format!("Started by {}", started.join(", "))),
        );
    } else if cameras.is_empty() && !state.cameras.is_empty() {
        out.push(
            Notification::new("camera", "camera-disabled-symbolic", "Camera off")
                .body("Nothing is using the camera")
                .urgency(Urgency::Low),
        );
    }
}
