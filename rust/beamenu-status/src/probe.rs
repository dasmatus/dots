//! The impure half: read a file, run a command, hand the text to
//! [`crate::parse`].
//!
//! Split by cost, because that split is the whole reason this crate exists.
//! [`live`] touches only `/proc` and `/sys` and is safe to call on every
//! keystroke. [`snapshot`] forks four to six processes and is not — it belongs
//! to the daemon, which runs it on a timer and leaves the result in
//! [`crate::cache`].

use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::model::{Live, Service, Snapshot, Volume};
use crate::parse::{self, BatteryReading};

/// The tunnel interface Proton VPN pins for both its backends, so its presence
/// is the connection. Lifted from waybar's `dots-vpn-pill`.
const VPN_INTERFACE: &str = "proton0";

/// The filesystems worth a row. Mirrors waybar's two `disk#*` modules.
const DISK_PATHS: &[&str] = &["/home", "/nix/store"];

/// `wpctl`'s name for whichever sink is currently the default.
///
/// Named here rather than spelled out at each call site because `dots-osd`
/// actuates the same two nodes this crate reads, and a typo in one of the four
/// places would silently move the volume of a node nobody is listening to.
pub const DEFAULT_SINK: &str = "@DEFAULT_AUDIO_SINK@";
/// The same for the default source.
pub const DEFAULT_SOURCE: &str = "@DEFAULT_AUDIO_SOURCE@";

/// Read a file, trimming it, treating any failure as absent.
fn slurp(path: impl AsRef<Path>) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
}

/// Run a command and return its stdout, or `None` if it could not run or
/// failed.
///
/// A missing binary is an ordinary outcome here: `wpctl` does not exist outside
/// a `PipeWire` session and `nmcli` does not exist without `NetworkManager`.
fn run(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The first entry in `dir` whose name starts with `prefix`.
///
/// Batteries are `BAT0` on most machines and `BAT1` on some, and backlights are
/// named after the driver (`amdgpu_bl1`, `intel_backlight`), so neither can be
/// hardcoded.
fn first_entry(dir: &str, prefix: &str) -> Option<std::path::PathBuf> {
    let mut names: Vec<_> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(prefix))
        })
        .collect();
    // Directory order is not guaranteed, and picking a different battery
    // between runs would make the row flicker between two percentages.
    names.sort();
    names.into_iter().next()
}

/// Everything readable in microseconds, taken fresh.
#[must_use]
pub fn live() -> Live {
    Live {
        battery: battery(),
        backlight: backlight(),
        memory: slurp("/proc/meminfo").as_deref().and_then(parse::meminfo),
        load: slurp("/proc/loadavg").as_deref().and_then(parse::loadavg),
        uptime_seconds: slurp("/proc/uptime").as_deref().and_then(parse::uptime),
        kernel: slurp("/proc/sys/kernel/osrelease"),
        temperature_millicelsius: hottest_zone(),
    }
}

/// The first battery, or `None` on a machine without one.
///
/// Public because `dots-osd` warns on low charge and wants this reading alone,
/// not the seven [`live`] takes to build a dashboard row.
#[must_use]
pub fn battery() -> Option<crate::model::Battery> {
    let dir = first_entry("/sys/class/power_supply", "BAT")?;
    let name = dir.file_name()?.to_str()?.to_string();
    let read = |file: &str| slurp(dir.join(file));

    // charge/current (µAh, µA) and energy/power (µWh, µW) are alternative
    // spellings; a machine exposes one pair, never both.
    let now = read("charge_now").or_else(|| read("energy_now"));
    let full = read("charge_full").or_else(|| read("energy_full"));
    let rate = read("current_now").or_else(|| read("power_now"));

    parse::battery(BatteryReading {
        name: &name,
        capacity: &read("capacity")?,
        status: &read("status")?,
        now: now.as_deref(),
        full: full.as_deref(),
        rate: rate.as_deref(),
    })
}

/// Panel brightness, or `None` where no backlight is exposed.
///
/// Public for the same reason [`battery`] is: `dots-osd` reads it back
/// immediately after `brightnessctl` moves it, to put the new percentage on
/// screen.
#[must_use]
pub fn backlight() -> Option<crate::model::Backlight> {
    let dir = first_entry("/sys/class/backlight", "")?;
    parse::backlight(
        &slurp(dir.join("brightness"))?,
        &slurp(dir.join("max_brightness"))?,
    )
}

/// The hottest thermal zone, in millidegrees.
///
/// Hottest rather than a named zone: which zone is the CPU differs per board,
/// and for a status row "how hot is this machine" is the question being asked.
fn hottest_zone() -> Option<i64> {
    let entries = std::fs::read_dir("/sys/class/thermal").ok()?;
    entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("thermal_zone"))
        })
        .filter_map(|zone| slurp(zone.join("temp"))?.parse::<i64>().ok())
        .max()
}

/// Everything that costs a fork. Runs on the daemon's timer, never inline.
#[must_use]
pub fn snapshot() -> Snapshot {
    let mut snapshot = snapshot_without_disks();
    snapshot.disks = disks();
    snapshot
}

/// The same, minus the two `df` forks.
///
/// Split out because a filesystem does not fill at the rate a volume slider
/// moves: the daemon refreshes this every five seconds and [`disks`] every
/// thirty, which is exactly the split waybar's module intervals used.
#[must_use]
pub fn snapshot_without_disks() -> Snapshot {
    let nmcli = run(
        "nmcli",
        &[
            "-t",
            "-f",
            "NAME,DEVICE,TYPE",
            "connection",
            "show",
            "--active",
        ],
    );

    Snapshot {
        captured_at: now_secs(),
        volume: audio(DEFAULT_SINK),
        microphone: audio(DEFAULT_SOURCE),
        network: nmcli.as_deref().and_then(parse::nmcli_active),
        vpn: Some(parse::vpn(
            Path::new("/sys/class/net").join(VPN_INTERFACE).exists(),
            nmcli
                .as_deref()
                .and_then(|raw| parse::nmcli_vpn_server(raw, VPN_INTERFACE)),
        )),
        mail_bridge: mail_bridge(),
        disks: Vec::new(),
    }
}

/// The filesystems worth a row, one `df` fork each.
#[must_use]
pub fn disks() -> Vec<crate::model::Disk> {
    DISK_PATHS.iter().filter_map(|path| disk(path)).collect()
}

/// One `wpctl` target's level and mute state.
///
/// `target` is a `wpctl` node name, in practice [`DEFAULT_SINK`] or
/// [`DEFAULT_SOURCE`]. Public so `dots-osd` reads a volume keypress back
/// through the same parser the dashboard uses, rather than growing a second
/// reading of `wpctl`'s output that could disagree with this one.
#[must_use]
pub fn audio(target: &str) -> Option<Volume> {
    run("wpctl", &["get-volume", target])
        .as_deref()
        .and_then(parse::wpctl_volume)
}

/// The Proton Mail Bridge user unit.
///
/// `is-active` exits non-zero when the unit is not running, which [`run`] maps
/// to `None` — but "stopped" is a real reading, not a failed probe. So the
/// status is taken from stdout regardless of exit code, and only a `systemctl`
/// that could not run at all counts as absent.
fn mail_bridge() -> Option<Service> {
    let output = Command::new("systemctl")
        .args(["--user", "is-active", "protonmail-bridge.service"])
        .output()
        .ok()?;
    Some(parse::systemctl_is_active(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

fn disk(path: &str) -> Option<crate::model::Disk> {
    run("df", &["-B1", "--output=used,size,pcent", path])
        .as_deref()
        .and_then(|raw| parse::df(raw, path))
}

/// Unix seconds, or 0 if the clock is before the epoch.
#[must_use]
pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}
