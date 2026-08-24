//! The strings a row actually shows.

use beamenu_status::format;
use beamenu_status::model::{
    Battery, BatteryState, Disk, Memory, Network, NetworkKind, Volume, Vpn,
};

#[test]
fn bytes_keep_one_decimal_only_where_it_reads() {
    assert_eq!(format::bytes(0), "0 B");
    assert_eq!(format::bytes(999), "999 B");
    assert_eq!(format::bytes(1024), "1.0 KiB");
    assert_eq!(format::bytes(1024 * 1024 * 9), "9.0 MiB");
    // Past ten the decimal stops earning its width in a launcher row.
    assert_eq!(format::bytes(1024 * 1024 * 42), "42 MiB");
    assert_eq!(format::bytes(493_837_352_960), "460 GiB");
}

#[test]
fn durations_switch_units_before_they_get_useless() {
    assert_eq!(format::duration(0), "0m");
    assert_eq!(format::duration(47 * 60), "47m");
    assert_eq!(format::duration(2 * 3600 + 14 * 60), "2h 14m");
    // An uptime row reading "412h" is correct and unreadable.
    assert_eq!(format::duration(170_297), "1d 23h");
}

#[test]
fn a_charging_battery_says_what_the_estimate_is_for() {
    let battery = Battery {
        name: "BAT1".into(),
        percent: 96,
        state: BatteryState::Charging,
        seconds_remaining: Some(841),
    };
    assert_eq!(format::battery_value(&battery), "96% · 14m");
    assert_eq!(format::battery_detail(&battery), "BAT1 · until full");
}

#[test]
fn a_full_battery_shows_no_countdown() {
    let battery = Battery {
        name: "BAT0".into(),
        percent: 100,
        state: BatteryState::Full,
        seconds_remaining: Some(0),
    };
    assert_eq!(format::battery_value(&battery), "100%");
    assert_eq!(format::battery_detail(&battery), "BAT0 · full");
}

#[test]
fn a_muted_sink_still_shows_the_level_it_will_return_to() {
    assert_eq!(
        format::volume_value(Volume {
            percent: 35,
            muted: true
        }),
        "muted (35%)"
    );
    assert_eq!(
        format::volume_value(Volume {
            percent: 35,
            muted: false
        }),
        "35%"
    );
}

#[test]
fn memory_reads_as_a_share_and_a_pair_of_sizes() {
    let memory = Memory {
        used: 4 * 1024 * 1024 * 1024,
        total: 16 * 1024 * 1024 * 1024,
    };
    assert_eq!(format::memory_value(memory), "25%");
    assert_eq!(format::memory_detail(memory), "4.0 GiB of 16 GiB in use");
}

#[test]
fn a_disk_names_the_path_that_was_asked_about() {
    let disk = Disk {
        path: "/nix/store".into(),
        used: 139_908_759_552,
        total: 493_837_352_960,
    };
    assert_eq!(format::disk_value(&disk), "28%");
    assert_eq!(
        format::disk_detail(&disk),
        "130 GiB of 460 GiB used on /nix/store"
    );
}

#[test]
fn the_network_row_leads_with_the_name_a_person_recognises() {
    let network = Network {
        kind: NetworkKind::Wifi,
        name: "HOME".into(),
        device: "wlp3s0".into(),
    };
    assert_eq!(format::network_value(Some(&network)), "HOME");
    assert_eq!(format::network_detail(Some(&network)), "Wi-Fi on wlp3s0");
}

#[test]
fn no_network_is_stated_rather_than_left_blank() {
    assert_eq!(format::network_value(None), "disconnected");
    assert_eq!(format::network_detail(None), "No active network connection");
}

#[test]
fn the_vpn_row_prefers_the_server_name_when_there_is_one() {
    assert_eq!(
        format::vpn_value(&Vpn {
            connected: true,
            server: Some("ProtonVPN SK#25".into())
        }),
        "ProtonVPN SK#25"
    );
    assert_eq!(
        format::vpn_value(&Vpn {
            connected: true,
            server: None
        }),
        "connected"
    );
    assert_eq!(
        format::vpn_value(&Vpn {
            connected: false,
            server: None
        }),
        "off"
    );
}

#[test]
fn temperature_rounds_millidegrees_to_whole_celsius() {
    assert_eq!(format::temperature(92_000), "92°C");
    assert_eq!(format::temperature(45_600), "46°C");
}

#[test]
fn the_bar_fills_in_proportion_and_never_overruns_its_track() {
    assert_eq!(format::bar(0, 10), "░░░░░░░░░░");
    assert_eq!(format::bar(50, 10), "█████░░░░░");
    assert_eq!(format::bar(100, 10), "██████████");
    assert_eq!(
        format::bar(200, 10).chars().count(),
        10,
        "a percentage past 100 must not stretch the bar"
    );
}
