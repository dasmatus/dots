//! The pure parsers, against fixtures captured from a real machine.

use beamenu_status::model::{BatteryState, NetworkKind};
use beamenu_status::parse::{self, BatteryReading};

#[test]
fn meminfo_uses_available_rather_than_free() {
    // Captured from /proc/meminfo. Free is 1.8 GiB but 11 GiB is available,
    // because most of the difference is reclaimable page cache. A readout
    // built on MemFree would claim this machine is 88% full; it is 26%.
    let raw = "\
MemTotal:       15703364 kB
MemFree:         1889236 kB
MemAvailable:   11544284 kB
Buffers:             664 kB
Cached:         10046396 kB
";
    let memory = parse::meminfo(raw).expect("a well-formed meminfo parses");

    assert_eq!(memory.total, 15_703_364 * 1024);
    assert_eq!(memory.used, (15_703_364 - 11_544_284) * 1024);
    assert_eq!(memory.percent(), 26);
}

#[test]
fn meminfo_without_the_fields_it_needs_is_absent() {
    assert!(parse::meminfo("Buffers: 664 kB\n").is_none());
    assert!(parse::meminfo("").is_none());
}

#[test]
fn loadavg_takes_the_three_windows() {
    let load = parse::loadavg("2.54 2.42 2.38 3/1177 1907636").expect("loadavg parses");
    assert!((load.one - 2.54).abs() < f64::EPSILON);
    assert!((load.five - 2.42).abs() < f64::EPSILON);
    assert!((load.fifteen - 2.38).abs() < f64::EPSILON);
}

#[test]
fn uptime_truncates_the_fractional_seconds() {
    assert_eq!(parse::uptime("170297.84 1094589.66"), Some(170_297));
    assert_eq!(parse::uptime(""), None);
    assert_eq!(parse::uptime("not-a-number"), None);
}

#[test]
fn backlight_is_a_ratio_of_the_panel_maximum() {
    assert_eq!(parse::backlight("65535", "65535").unwrap().percent, 100);
    assert_eq!(parse::backlight("32768", "65535").unwrap().percent, 50);
    // A max of zero would divide by zero; it must read as absent, not panic.
    assert_eq!(parse::backlight("0", "0").unwrap().percent, 0);
}

#[test]
fn a_battery_reporting_charge_and_current_yields_a_time_estimate() {
    // This machine's BAT1: charge_now/current_now in µAh and µA, not the
    // energy_now/power_now spelling. The units cancel in the division.
    let battery = parse::battery(BatteryReading {
        name: "BAT1",
        capacity: "96",
        status: "Charging",
        now: Some("4501000"),
        full: Some("5000000"),
        rate: Some("2136000"),
    })
    .expect("a complete reading parses");

    assert_eq!(battery.percent, 96);
    assert_eq!(battery.state, BatteryState::Charging);
    // (5000000 - 4501000) * 3600 / 2136000 = 841s to full
    assert_eq!(battery.seconds_remaining, Some(841));
}

#[test]
fn a_discharging_battery_counts_down_from_what_is_left() {
    let battery = parse::battery(BatteryReading {
        name: "BAT0",
        capacity: "50",
        status: "Discharging",
        now: Some("2500000"),
        full: Some("5000000"),
        rate: Some("1000000"),
    })
    .expect("a complete reading parses");

    assert_eq!(battery.state, BatteryState::Discharging);
    assert_eq!(battery.seconds_remaining, Some(9000));
}

#[test]
fn a_zero_rate_gives_no_estimate_rather_than_a_zero_one() {
    // current_now reads zero for several seconds after a charger is plugged
    // in. "0m remaining" would be a lie; no estimate is the truth.
    let battery = parse::battery(BatteryReading {
        name: "BAT0",
        capacity: "80",
        status: "Charging",
        now: Some("4000000"),
        full: Some("5000000"),
        rate: Some("0"),
    })
    .expect("a reading without a rate still parses");

    assert_eq!(battery.seconds_remaining, None);
}

#[test]
fn an_unknown_battery_status_does_not_lose_the_percentage() {
    // ThinkPads in conservation mode report "Not charging".
    let battery = parse::battery(BatteryReading {
        name: "BAT0",
        capacity: "60",
        status: "Not charging",
        ..BatteryReading::default()
    })
    .expect("capacity and status are all that is required");

    assert_eq!(battery.percent, 60);
    assert_eq!(battery.state, BatteryState::Unknown);
    assert_eq!(battery.seconds_remaining, None);
}

#[test]
fn a_battery_overshooting_a_hundred_percent_is_clamped() {
    let battery = parse::battery(BatteryReading {
        name: "BAT0",
        capacity: "104",
        status: "Full",
        ..BatteryReading::default()
    })
    .expect("a clamped reading still parses");
    assert_eq!(battery.percent, 100);
}

#[test]
fn wpctl_reports_a_ratio_and_flags_mute_separately() {
    let volume = parse::wpctl_volume("Volume: 0.10\n").expect("wpctl output parses");
    assert_eq!(volume.percent, 10);
    assert!(!volume.muted);

    let muted = parse::wpctl_volume("Volume: 0.35 [MUTED]\n").expect("a muted sink parses");
    assert_eq!(muted.percent, 35);
    assert!(muted.muted, "mute is independent of the level");
}

#[test]
fn wpctl_boost_above_one_is_not_clamped_to_a_hundred() {
    // wpctl really does report software boost above 1.0, and a row claiming
    // 100% while the sink is at 150% would hide clipping.
    let volume = parse::wpctl_volume("Volume: 1.50").expect("boost parses");
    assert_eq!(volume.percent, 150);
}

#[test]
fn nmcli_prefers_wireless_over_wired_and_ignores_tunnels() {
    // Captured live: a Proton kill-switch dummy, the Wi-Fi, the WireGuard
    // tunnel, and loopback. waybar's built-in module picked the kill-switch
    // interface here and leaked its IP, which is the bug the pill fixed.
    let raw = "\
pvpn-killswitch-perm:pvpnksintrf1:dummy
HOME:wlp3s0:802-11-wireless
ProtonVPN SK#25:proton0:wireguard
lo:lo:loopback
";
    let network = parse::nmcli_active(raw).expect("an active connection is found");

    assert_eq!(network.kind, NetworkKind::Wifi);
    assert_eq!(network.name, "HOME");
    assert_eq!(network.device, "wlp3s0");
}

#[test]
fn nmcli_falls_back_to_the_first_wired_connection() {
    let raw = "\
lo:lo:loopback
office:enp0s31f6:802-3-ethernet
dock:enp0s20f0u1:802-3-ethernet
";
    let network = parse::nmcli_active(raw).expect("a wired connection is found");

    assert_eq!(network.kind, NetworkKind::Ethernet);
    assert_eq!(network.name, "office", "the first wired one wins");
}

#[test]
fn nmcli_with_nothing_but_tunnels_reports_no_network() {
    let raw = "lo:lo:loopback\nProtonVPN SK#25:proton0:wireguard\n";
    assert!(parse::nmcli_active(raw).is_none());
}

#[test]
fn the_vpn_server_name_comes_from_the_tunnel_interface() {
    let raw = "HOME:wlp3s0:802-11-wireless\nProtonVPN SK#25:proton0:wireguard\n";
    assert_eq!(
        parse::nmcli_vpn_server(raw, "proton0").as_deref(),
        Some("ProtonVPN SK#25")
    );
    assert_eq!(parse::nmcli_vpn_server(raw, "proton1"), None);
}

#[test]
fn a_disconnected_vpn_carries_no_stale_server_name() {
    let vpn = parse::vpn(false, Some("ProtonVPN SK#25".into()));
    assert!(!vpn.connected);
    assert_eq!(vpn.server, None, "a name without a tunnel would be stale");
}

#[test]
fn systemctl_is_active_reads_the_word() {
    assert!(parse::systemctl_is_active("active\n").active);
    assert!(!parse::systemctl_is_active("inactive\n").active);
    assert!(!parse::systemctl_is_active("failed\n").active);
    assert!(!parse::systemctl_is_active("").active);
}

#[test]
fn df_is_parsed_by_position_because_its_header_is_localised() {
    // Captured on a German locale. Matching on "Used" or "Size" would work on
    // an English machine and nowhere else.
    let raw = "\
     Benutzt    1B-Blöcke Verw%
139908759552 493837352960   29%
";
    let disk = parse::df(raw, "/home").expect("df output parses");

    assert_eq!(disk.path, "/home");
    assert_eq!(disk.used, 139_908_759_552);
    assert_eq!(disk.total, 493_837_352_960);
    assert_eq!(
        disk.percent(),
        28,
        "derived, not read from the pcent column"
    );
}

#[test]
fn df_with_only_a_header_is_absent() {
    assert!(parse::df("Used Size Use%\n", "/home").is_none());
}
