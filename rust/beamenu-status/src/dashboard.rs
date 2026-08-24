//! The live dashboard's markdown.
//!
//! beamenu-canvas accepts a closed set of component trees and none of them is a
//! gauge, a table widget or a chart — `detail` carries markdown and that is the
//! whole drawing surface. So the bars here are text
//! ([`crate::format::bar`]), which is not a workaround: the canvas escapes
//! everything it did not generate itself, and staying inside markdown is what
//! keeps that guarantee intact.

use std::fmt::Write as _;

use crate::format;
use crate::model::{Live, Snapshot};

/// Width of the text gauges, in cells.
const BAR_WIDTH: usize = 20;

/// Accumulates rows, emphasising the one the dashboard was opened from.
struct Table<'a> {
    out: String,
    highlight: &'a str,
}

impl<'a> Table<'a> {
    fn new(highlight: &'a str) -> Self {
        Self {
            out: String::from("# System\n\n"),
            highlight,
        }
    }

    /// A row with a proportion worth drawing.
    fn gauge(&mut self, id: &str, label: &str, value: &str, percent: u8) {
        let mark = self.mark(id);
        let bar = format::bar(percent, BAR_WIDTH);
        let _ = writeln!(self.out, "{mark}{label}{mark} `{bar}` {value}\n");
    }

    /// A row that is a fact rather than a proportion.
    fn fact(&mut self, id: &str, label: &str, value: &str) {
        let mark = self.mark(id);
        let _ = writeln!(self.out, "{mark}{label}{mark} — {value}\n");
    }

    fn mark(&self, id: &str) -> &'static str {
        if id == self.highlight {
            "**"
        } else {
            ""
        }
    }
}

/// Render one frame of the dashboard.
///
/// `highlight` is the metric id the dashboard was opened from, emphasised so
/// that arriving from the volume row does not mean hunting for volume in a
/// table. An id matching nothing highlights nothing.
#[must_use]
pub fn render(live: &Live, snapshot: Option<&Snapshot>, highlight: &str) -> String {
    let mut table = Table::new(highlight);
    push_live(&mut table, live);
    if let Some(snapshot) = snapshot {
        push_snapshot(&mut table, snapshot);
    }
    push_host(&mut table, live);
    table.out
}

/// The readings taken fresh for this frame.
fn push_live(table: &mut Table<'_>, live: &Live) {
    if let Some(battery) = &live.battery {
        table.gauge(
            "battery",
            "Battery",
            &format::battery_value(battery),
            battery.percent,
        );
    }
    if let Some(memory) = live.memory {
        table.gauge(
            "memory",
            "Memory",
            &format::memory_detail(memory),
            memory.percent(),
        );
    }
    if let Some(load) = live.load {
        table.fact(
            "load",
            "Load",
            &format!("{:.2} {:.2} {:.2}", load.one, load.five, load.fifteen),
        );
    }
    if let Some(backlight) = live.backlight {
        table.gauge(
            "backlight",
            "Backlight",
            &format!("{}%", backlight.percent),
            backlight.percent,
        );
    }
    if let Some(millicelsius) = live.temperature_millicelsius {
        table.fact(
            "temperature",
            "Temperature",
            &format::temperature(millicelsius),
        );
    }
}

/// The readings the daemon captured, which may be a few seconds old.
fn push_snapshot(table: &mut Table<'_>, snapshot: &Snapshot) {
    if let Some(volume) = snapshot.volume {
        // A boosted sink reads above 100%; the bar tops out while the number
        // keeps going, which is the honest way round.
        let filled = u8::try_from(volume.percent.min(100)).unwrap_or(100);
        table.gauge("volume", "Volume", &format::volume_value(volume), filled);
    }
    if let Some(microphone) = snapshot.microphone {
        table.fact(
            "microphone",
            "Microphone",
            &format::volume_value(microphone),
        );
    }

    table.fact(
        "network",
        "Network",
        &format!(
            "{} — {}",
            format::network_value(snapshot.network.as_ref()),
            format::network_detail(snapshot.network.as_ref())
        ),
    );

    if let Some(vpn) = &snapshot.vpn {
        table.fact("vpn", "VPN", &format::vpn_value(vpn));
    }
    if let Some(bridge) = snapshot.mail_bridge {
        table.fact(
            "mail-bridge",
            "Mail Bridge",
            if bridge.active { "running" } else { "stopped" },
        );
    }
    for disk in &snapshot.disks {
        table.gauge(
            "disk",
            &format!("Disk {}", disk.path),
            &format::disk_detail(disk),
            disk.percent(),
        );
    }
}

/// The slow-moving facts, last because nobody opens a dashboard for them.
fn push_host(table: &mut Table<'_>, live: &Live) {
    if let Some(uptime) = live.uptime_seconds {
        table.fact("uptime", "Uptime", &format::duration(uptime));
    }
    if let Some(kernel) = &live.kernel {
        table.fact("kernel", "Kernel", kernel);
    }
}
