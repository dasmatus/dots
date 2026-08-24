//! Live system readouts, as rows you can search.
//!
//! What waybar shows in the bar, asked a question instead of glanced at: type
//! "wifi" and the row tells you the SSID, type "disk" and it tells you what is
//! left. Everything here answers to the words a person actually types rather
//! than to the label on the row, which is what [`Item::keywords`] is for.
//!
//! Two sources, split by what they cost. `/proc` and `/sys` are read here and
//! now, on every keystroke, because they are microseconds. Anything needing a
//! subprocess — `wpctl`, `nmcli`, `systemctl`, `df`, tens of milliseconds
//! apiece — is read by `beamenu --status-daemon` on a timer and picked up from
//! its snapshot file. Forking five processes per keystroke would be felt.

use std::path::Path;

use beamenu_status::model::{Live, Snapshot};
use beamenu_status::{cache, format, probe};

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider};

/// The plugin manifest the live dashboard is declared in, relative to the
/// config dir. Home Manager writes it; a missing file simply means the
/// dashboard action does nothing, the same way a missing sidecar binary does.
const DASHBOARD_MANIFEST: &str = "plugins/status-dashboard.json";

/// The command id inside that manifest.
const DASHBOARD_COMMAND: &str = "dashboard";

pub struct Status;

/// One row under construction.
///
/// Exists so every metric is built the same way — id prefix, keywords,
/// dashboard alt-action — rather than each arm of a long function remembering
/// to do all three.
struct Row {
    id: String,
    title: String,
    /// Static because every metric's aliases are known at compile time; the
    /// disk rows are the only ones whose *title* varies, and only by path.
    keywords: &'static [&'static str],
    value: String,
    detail: String,
    /// What Enter does, when the metric has something worth doing.
    action: Option<Action>,
}

impl Provider for Status {
    fn id(&self) -> &'static str {
        "status"
    }

    fn section(&self) -> &'static str {
        "Status"
    }

    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        let live = probe::live();
        let snapshot = cache::load(&cache::path(&ctx.state_dir));
        let stale = snapshot
            .as_ref()
            .is_some_and(|snapshot| cache::is_stale(snapshot, probe::now_secs()));

        items(
            &live,
            snapshot.as_ref(),
            stale,
            &ctx.config_dir.join(DASHBOARD_MANIFEST),
        )
    }
}

/// Build the rows for a given pair of readings.
///
/// Public, and taking its readings as arguments rather than probing, because
/// otherwise the only way to test this is on a machine that happens to have the
/// battery, network and daemon state the test wants. Everything impure lives in
/// [`Provider::query`] above.
#[must_use]
pub fn items(
    live: &Live,
    snapshot: Option<&Snapshot>,
    stale: bool,
    dashboard_manifest: &Path,
) -> Vec<Item> {
    rows(live, snapshot, stale)
        .into_iter()
        .map(|row| row.into_item(dashboard_manifest))
        .collect()
}

impl Row {
    fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        keywords: &'static [&'static str],
        value: String,
        detail: String,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            keywords,
            value,
            detail,
            action: None,
        }
    }

    /// Give the row something to do on Enter.
    fn acts(mut self, command: &str) -> Self {
        self.action = Some(Action::Shell(command.to_string()));
        self
    }

    fn into_item(self, manifest: &Path) -> Item {
        let dashboard = Action::View {
            manifest: manifest.to_path_buf(),
            command: DASHBOARD_COMMAND.to_string(),
            query: self.id.clone(),
        };

        // A metric with no actuator opens the dashboard on Enter, so no status
        // row is a dead end.
        let primary = self.action.unwrap_or_else(|| dashboard.clone());

        Item::new(format!("status:{}", self.id), self.title, primary)
            .keywords(self.keywords.iter().copied())
            .subtitle(self.detail)
            .accessory(self.value.clone())
            .alt("Open live dashboard", dashboard)
            .alt("Copy value", Action::Copy(self.value))
    }
}

/// Every metric that has a reading, in the order they should appear.
fn rows(live: &Live, snapshot: Option<&Snapshot>, stale: bool) -> Vec<Row> {
    let mut rows = Vec::new();

    if let Some(battery) = &live.battery {
        rows.push(Row::new(
            "battery",
            "Battery",
            &["battery", "power", "charge", "bat"],
            format::battery_value(battery),
            format::battery_detail(battery),
        ));
    }

    if let Some(snapshot) = snapshot {
        push_cached(&mut rows, snapshot, stale);
    }

    if let Some(memory) = live.memory {
        rows.push(Row::new(
            "memory",
            "Memory",
            &["memory", "ram", "mem", "free"],
            format::memory_value(memory),
            format::memory_detail(memory),
        ));
    }

    if let Some(load) = live.load {
        rows.push(Row::new(
            "load",
            "CPU Load",
            &["load", "cpu", "processor", "average"],
            format!("{:.2}", load.one),
            format!(
                "{:.2} over 1m, {:.2} over 5m, {:.2} over 15m",
                load.one, load.five, load.fifteen
            ),
        ));
    }

    if let Some(backlight) = live.backlight {
        rows.push(Row::new(
            "backlight",
            "Backlight",
            &["backlight", "brightness", "screen", "display"],
            format!("{}%", backlight.percent),
            "Screen brightness".to_string(),
        ));
    }

    if let Some(millicelsius) = live.temperature_millicelsius {
        rows.push(Row::new(
            "temperature",
            "Temperature",
            &["temperature", "temp", "heat", "thermal", "fan"],
            format::temperature(millicelsius),
            "Hottest thermal zone".to_string(),
        ));
    }

    if let Some(uptime) = live.uptime_seconds {
        rows.push(Row::new(
            "uptime",
            "Uptime",
            &["uptime", "boot", "running"],
            format::duration(uptime),
            "Time since boot".to_string(),
        ));
    }

    if let Some(kernel) = &live.kernel {
        rows.push(Row::new(
            "kernel",
            "Kernel",
            &["kernel", "linux", "version", "nixos"],
            kernel.clone(),
            "Running kernel release".to_string(),
        ));
    }

    rows
}

/// The rows that come from the daemon's snapshot.
///
/// `stale` marks every one of them at once rather than per metric: they were
/// all captured in the same pass, so if one is old they all are.
fn push_cached(rows: &mut Vec<Row>, snapshot: &Snapshot, stale: bool) {
    let age = |detail: String| {
        if stale {
            format!("{detail} · reading may be out of date")
        } else {
            detail
        }
    };

    if let Some(volume) = snapshot.volume {
        rows.push(
            Row::new(
                "volume",
                "Volume",
                &["volume", "sound", "audio", "speaker", "mute", "vol"],
                format::volume_value(volume),
                age("Default audio output — Enter to toggle mute".to_string()),
            )
            .acts("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
        );
    }

    if let Some(microphone) = snapshot.microphone {
        rows.push(
            Row::new(
                "microphone",
                "Microphone",
                &["microphone", "mic", "input", "record"],
                format::volume_value(microphone),
                age("Default audio input — Enter to toggle mute".to_string()),
            )
            .acts("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
        );
    }

    rows.push(
        Row::new(
            "network",
            "Network",
            &["network", "wifi", "wi-fi", "ssid", "internet", "connection"],
            format::network_value(snapshot.network.as_ref()),
            age(format::network_detail(snapshot.network.as_ref())),
        )
        .acts("nm-connection-editor"),
    );

    if let Some(vpn) = &snapshot.vpn {
        let detail = if vpn.connected {
            "Proton VPN — connected"
        } else {
            "Proton VPN — not connected"
        };
        rows.push(
            Row::new(
                "vpn",
                "VPN",
                &["vpn", "proton", "tunnel", "wireguard"],
                format::vpn_value(vpn),
                age(detail.to_string()),
            )
            .acts("protonvpn-app"),
        );
    }

    if let Some(bridge) = snapshot.mail_bridge {
        let (value, detail) = if bridge.active {
            ("running", "Proton Mail Bridge — IMAP :1143 / SMTP :1025")
        } else {
            ("stopped", "Proton Mail Bridge — Enter to restart")
        };
        rows.push(
            Row::new(
                "mail-bridge",
                "Mail Bridge",
                &["bridge", "mail", "proton", "imap", "smtp", "email"],
                value.to_string(),
                age(detail.to_string()),
            )
            .acts("systemctl --user restart protonmail-bridge.service"),
        );
    }

    for disk in &snapshot.disks {
        // Every filesystem shares one id prefix and one keyword set; the path
        // is what tells them apart, so it goes in the title.
        let (id, title, keywords): (&str, &str, &[&str]) = match disk.path.as_str() {
            "/home" => (
                "disk-home",
                "Disk — /home",
                &["disk", "storage", "home", "space", "df"],
            ),
            "/nix/store" => (
                "disk-nix",
                "Disk — /nix/store",
                &["disk", "storage", "nix", "store", "space", "df"],
            ),
            _ => ("disk", "Disk", &["disk", "storage", "space", "df"]),
        };
        let mut row = Row::new(
            id,
            title,
            keywords,
            format::disk_value(disk),
            age(format::disk_detail(disk)),
        );
        row.action = Some(Action::Shell(format!(
            "xdg-open {}",
            shell_quote(&disk.path)
        )));
        rows.push(row);
    }
}

/// Single-quote a path for a shell command line.
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}
