//! The status provider's rows: what they show, what they answer to, and what
//! Enter does.

use std::path::Path;

use beamenu::item::{Action, Item};
use beamenu::providers::status;
use beamenu::rank;
use beamenu_status::model::{
    Backlight, Battery, BatteryState, Disk, Live, Memory, Network, NetworkKind, Service, Snapshot,
    Volume, Vpn,
};

fn live() -> Live {
    Live {
        battery: Some(Battery {
            name: "BAT1".into(),
            percent: 96,
            state: BatteryState::Charging,
            seconds_remaining: Some(841),
        }),
        backlight: Some(Backlight { percent: 60 }),
        memory: Some(Memory {
            used: 4 * 1024 * 1024 * 1024,
            total: 16 * 1024 * 1024 * 1024,
        }),
        load: Some(beamenu_status::model::Load {
            one: 2.54,
            five: 2.42,
            fifteen: 2.38,
        }),
        uptime_seconds: Some(170_297),
        kernel: Some("7.1.8".into()),
        temperature_millicelsius: Some(92_000),
    }
}

fn snapshot() -> Snapshot {
    Snapshot {
        captured_at: 1_700_000_000,
        volume: Some(Volume {
            percent: 10,
            muted: false,
        }),
        microphone: Some(Volume {
            percent: 100,
            muted: true,
        }),
        network: Some(Network {
            kind: NetworkKind::Wifi,
            name: "HOME".into(),
            device: "wlp3s0".into(),
        }),
        vpn: Some(Vpn {
            connected: true,
            server: Some("ProtonVPN SK#25".into()),
        }),
        mail_bridge: Some(Service { active: true }),
        disks: vec![Disk {
            path: "/home".into(),
            used: 139_908_759_552,
            total: 493_837_352_960,
        }],
    }
}

fn manifest() -> &'static Path {
    Path::new("/home/someone/.config/beamenu/plugins/status-dashboard.json")
}

fn rows() -> Vec<Item> {
    status::items(&live(), Some(&snapshot()), false, manifest())
}

fn find<'a>(rows: &'a [Item], id: &str) -> &'a Item {
    rows.iter()
        .find(|row| row.id == format!("status:{id}"))
        .unwrap_or_else(|| panic!("no row with id status:{id}"))
}

#[test]
fn every_reading_present_becomes_exactly_one_row() {
    let rows = rows();
    let ids: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();

    for expected in [
        "status:battery",
        "status:volume",
        "status:microphone",
        "status:network",
        "status:vpn",
        "status:mail-bridge",
        "status:disk-home",
        "status:memory",
        "status:load",
        "status:backlight",
        "status:temperature",
        "status:uptime",
        "status:kernel",
    ] {
        assert!(ids.contains(&expected), "{expected} missing from {ids:?}");
    }
}

#[test]
fn a_row_id_is_stable_across_readings_so_frecency_still_works() {
    // Two very different machine states must produce the same ids, or every
    // change to a percentage would look like a brand new row to the frecency
    // store and ranking history would never accumulate.
    let mut other = live();
    other.battery = Some(Battery {
        name: "BAT1".into(),
        percent: 4,
        state: BatteryState::Discharging,
        seconds_remaining: Some(600),
    });

    let a = find(&rows(), "battery").id.clone();
    let b = status::items(&other, Some(&snapshot()), false, manifest());
    assert_eq!(a, find(&b, "battery").id);
}

#[test]
fn the_value_goes_in_the_accessory_and_the_detail_in_the_subtitle() {
    let rows = rows();
    let battery = find(&rows, "battery");

    assert_eq!(battery.title, "Battery");
    assert_eq!(battery.accessory.as_deref(), Some("96% · 14m"));
    assert_eq!(battery.subtitle.as_deref(), Some("BAT1 · until full"));
}

#[test]
fn readings_absent_from_the_machine_produce_no_row_rather_than_a_zero() {
    // A desktop has no battery and no backlight; those rows must vanish, not
    // read 0%.
    let bare = Live {
        memory: live().memory,
        ..Live::default()
    };
    let rows = status::items(&bare, None, false, manifest());
    let ids: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();

    assert!(ids.contains(&"status:memory"));
    assert!(!ids.contains(&"status:battery"));
    assert!(!ids.contains(&"status:backlight"));
    // Nothing from the snapshot either, since there was no snapshot.
    assert!(!ids.contains(&"status:network"));
}

#[test]
fn a_stale_snapshot_says_so_instead_of_presenting_old_data_as_current() {
    let fresh = status::items(&live(), Some(&snapshot()), false, manifest());
    let stale = status::items(&live(), Some(&snapshot()), true, manifest());

    assert!(!find(&fresh, "network")
        .subtitle
        .as_deref()
        .unwrap()
        .contains("out of date"));
    assert!(find(&stale, "network")
        .subtitle
        .as_deref()
        .unwrap()
        .contains("out of date"));

    // Live readings are never stale — they were taken this keystroke.
    assert!(!find(&stale, "battery")
        .subtitle
        .as_deref()
        .unwrap()
        .contains("out of date"));
}

#[test]
fn the_network_row_answers_to_wifi_and_ssid_without_showing_them() {
    let rows = rows();
    let network = find(&rows, "network");

    assert_eq!(network.title, "Network", "the title stays clean");
    for typed in ["wifi", "ssid", "internet", "connection"] {
        assert!(
            rank::match_score(network, typed).is_some(),
            "the network row should answer to {typed:?}"
        );
    }
}

#[test]
fn a_title_match_outranks_a_keyword_match() {
    // "Memory" answers to "mem" by title; the network row must not outrank it
    // just because some alias happens to fuzzy-match too.
    let rows = rows();
    let memory = rank::match_score(find(&rows, "memory"), "memory").expect("title matches");
    let network = rank::match_score(find(&rows, "network"), "memory");

    assert!(
        network.is_none_or(|network| network < memory),
        "keyword matches must sit strictly below title matches"
    );
}

#[test]
fn a_metric_with_an_actuator_runs_it_on_enter() {
    let rows = rows();

    assert_eq!(
        find(&rows, "volume").action,
        Action::Shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle".into())
    );
    assert_eq!(
        find(&rows, "mail-bridge").action,
        Action::Shell("systemctl --user restart protonmail-bridge.service".into())
    );
}

#[test]
fn a_metric_with_no_actuator_opens_the_dashboard_rather_than_doing_nothing() {
    let rows = rows();
    let uptime = find(&rows, "uptime");

    match &uptime.action {
        Action::View {
            manifest: path,
            command,
            query,
        } => {
            assert_eq!(path, manifest());
            assert_eq!(command, "dashboard");
            assert_eq!(query, "uptime", "the dashboard opens on this metric");
        }
        other => panic!("expected a dashboard view, got {other:?}"),
    }
}

#[test]
fn every_row_offers_the_dashboard_and_a_copy_in_the_action_panel() {
    for row in rows() {
        let labels: Vec<&str> = row
            .alt_actions
            .iter()
            .map(|(label, _)| label.as_str())
            .collect();
        assert!(
            labels.contains(&"Open live dashboard"),
            "{} lacks the dashboard action",
            row.id
        );
        assert!(
            labels.contains(&"Copy value"),
            "{} lacks the copy action",
            row.id
        );
    }
}

#[test]
fn disk_rows_are_told_apart_by_path() {
    let mut two = snapshot();
    two.disks = vec![
        Disk {
            path: "/home".into(),
            used: 1,
            total: 100,
        },
        Disk {
            path: "/nix/store".into(),
            used: 2,
            total: 100,
        },
    ];
    let rows = status::items(&live(), Some(&two), false, manifest());

    assert_eq!(find(&rows, "disk-home").title, "Disk — /home");
    assert_eq!(find(&rows, "disk-nix").title, "Disk — /nix/store");
}
