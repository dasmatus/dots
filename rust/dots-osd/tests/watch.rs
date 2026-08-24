//! The watcher's diff rules, driven by two structs rather than by a machine
//! whose disk somebody had to fill up first.
//!
//! Two properties are worth stating up front, because most of what follows is
//! one of them. Events (a network appearing, a camera switching on) say nothing
//! on the first observation, since a watcher that has just started has not
//! witnessed a change. Conditions (a disk already past 90%) do speak on the
//! first observation, since arriving to find one is exactly when you want to be
//! told.

use beamenu_status::model::{
    Battery, BatteryState, Disk, Network, NetworkKind, Service, Snapshot, Vpn,
};
use dots_osd::model::{Linger, Urgency};
use dots_osd::watch::{advance, Camera, Observed, State};

const GIB: u64 = 1024 * 1024 * 1024;

/// A filesystem at `percent` of a fixed 100 GiB.
fn disk(path: &str, percent: u64) -> Disk {
    Disk {
        path: path.to_string(),
        used: percent * GIB,
        total: 100 * GIB,
    }
}

fn with_disks(disks: Vec<Disk>) -> Observed {
    Observed {
        snapshot: Some(Snapshot {
            disks,
            ..Snapshot::default()
        }),
        ..Observed::default()
    }
}

fn wifi(name: &str) -> Network {
    Network {
        kind: NetworkKind::Wifi,
        name: name.to_string(),
        device: "wlan0".to_string(),
    }
}

fn with_network(network: Option<Network>) -> Observed {
    Observed {
        snapshot: Some(Snapshot {
            network,
            ..Snapshot::default()
        }),
        ..Observed::default()
    }
}

fn with_vpn(connected: bool, server: Option<&str>) -> Observed {
    Observed {
        snapshot: Some(Snapshot {
            vpn: Some(Vpn {
                connected,
                server: server.map(ToString::to_string),
            }),
            ..Snapshot::default()
        }),
        ..Observed::default()
    }
}

fn with_bridge(active: bool) -> Observed {
    Observed {
        snapshot: Some(Snapshot {
            mail_bridge: Some(Service { active }),
            ..Snapshot::default()
        }),
        ..Observed::default()
    }
}

fn with_battery(percent: u8, state: BatteryState) -> Observed {
    Observed {
        battery: Some(Battery {
            name: "BAT0".to_string(),
            percent,
            state,
            seconds_remaining: None,
        }),
        ..Observed::default()
    }
}

fn with_cameras(processes: &[&str]) -> Observed {
    Observed {
        cameras: Some(
            processes
                .iter()
                .map(|process| Camera {
                    process: (*process).to_string(),
                })
                .collect(),
        ),
        ..Observed::default()
    }
}

/// Fold a sequence of observations, returning only what the last one earned.
fn last(observations: &[Observed]) -> Vec<dots_osd::model::Notification> {
    let mut state = State::new();
    let mut out = Vec::new();
    for observed in observations {
        out = advance(&mut state, observed);
    }
    out
}

#[test]
fn a_full_disk_is_announced_on_the_first_observation() {
    let sent = last(&[with_disks(vec![disk("/home", 95)])]);

    assert_eq!(sent.len(), 1, "arriving to find /home at 95% is news");
    assert_eq!(sent[0].summary, "Disk /home");
    assert_eq!(sent[0].urgency, Urgency::Critical);
    assert_eq!(sent[0].value, Some(95));
}

#[test]
fn a_healthy_disk_says_nothing_on_the_first_observation() {
    assert!(last(&[with_disks(vec![disk("/home", 50)])]).is_empty());
}

#[test]
fn crossing_eighty_percent_warns_once() {
    let crossed = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 82)]),
    ]);
    assert_eq!(crossed.len(), 1);
    assert_eq!(crossed[0].urgency, Urgency::Normal);
    assert!(
        crossed[0].body.contains("82%"),
        "body should carry the reading, got {:?}",
        crossed[0].body
    );

    let again = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 82)]),
        with_disks(vec![disk("/home", 85)]),
    ]);
    assert!(again.is_empty(), "still in the same band, so still silent");
}

#[test]
fn leaving_a_band_needs_more_than_entering_it_did() {
    // 78 is below the 80 that raised the warning, but inside the margin that
    // stops a filesystem hovering on the line from announcing itself every
    // tick.
    let inside_margin = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 82)]),
        with_disks(vec![disk("/home", 78)]),
    ]);
    assert!(inside_margin.is_empty());

    let cleared = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 82)]),
        with_disks(vec![disk("/home", 70)]),
    ]);
    assert_eq!(cleared.len(), 1);
    assert_eq!(cleared[0].urgency, Urgency::Low);
    assert!(cleared[0].body.starts_with("Back down to"));
}

#[test]
fn ninety_percent_escalates_to_critical() {
    let sent = last(&[
        with_disks(vec![disk("/home", 82)]),
        with_disks(vec![disk("/home", 92)]),
    ]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].urgency, Urgency::Critical);
}

#[test]
fn each_filesystem_carries_its_own_band() {
    let sent = last(&[
        with_disks(vec![disk("/home", 50), disk("/nix/store", 50)]),
        with_disks(vec![disk("/home", 95), disk("/nix/store", 50)]),
    ]);
    assert_eq!(sent.len(), 1, "only /home moved");
    assert_eq!(sent[0].summary, "Disk /home");
}

#[test]
fn two_filesystems_crossing_at_once_do_not_replace_each_other() {
    let sent = last(&[
        with_disks(vec![disk("/home", 50), disk("/nix/store", 50)]),
        with_disks(vec![disk("/home", 85), disk("/nix/store", 95)]),
    ]);
    assert_eq!(sent.len(), 2);

    // A shared stack tag would mean the second notification replaced the first
    // on screen, and the more urgent of the two is the one that would vanish.
    let tags: Vec<&str> = sent.iter().map(|n| n.tag).collect();
    assert_ne!(tags[0], tags[1], "got {tags:?}");
}

#[test]
fn a_network_appearing_is_silent_on_arrival_and_loud_afterwards() {
    assert!(
        last(&[with_network(Some(wifi("home")))]).is_empty(),
        "the watcher arrived, it did not witness a connection"
    );

    let sent = last(&[with_network(None), with_network(Some(wifi("home")))]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Wi-Fi");
    assert_eq!(sent[0].body, "Connected to home");
    assert_eq!(sent[0].urgency, Urgency::Low);
}

#[test]
fn losing_the_network_is_reported() {
    let sent = last(&[with_network(Some(wifi("home"))), with_network(None)]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Network");
    assert!(sent[0].body.starts_with("Disconnected"));
}

#[test]
fn moving_between_networks_names_the_new_one() {
    let sent = last(&[
        with_network(Some(wifi("home"))),
        with_network(Some(wifi("cafe"))),
    ]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].body, "Now on cafe");
}

#[test]
fn staying_on_one_network_says_nothing() {
    let sent = last(&[
        with_network(Some(wifi("home"))),
        with_network(Some(wifi("home"))),
    ]);
    assert!(sent.is_empty());
}

#[test]
fn a_vpn_drop_is_the_one_change_worth_interrupting_for() {
    let sent = last(&[with_vpn(true, Some("NL#42")), with_vpn(false, None)]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "VPN");
    assert_eq!(sent[0].urgency, Urgency::Critical);
    assert!(sent[0].body.contains("no longer tunnelled"));
}

#[test]
fn the_things_worth_acting_on_stay_up_longer() {
    // The timeout travels with the notification rather than being left to the
    // daemon's per-urgency default, so it is worth pinning that the warnings
    // a person needs to see are the ones that linger.
    let drop = last(&[with_vpn(true, Some("NL#42")), with_vpn(false, None)]);
    assert_eq!(drop[0].linger, Linger::Long);

    let full = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 95)]),
    ]);
    assert_eq!(full[0].linger, Linger::Long);

    // A filesystem merely getting full is not something to interrupt over.
    let filling = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 82)]),
    ]);
    assert_eq!(filling[0].linger, Linger::Normal);

    // The charger going in is a fact you caused and are watching for.
    let plugged = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(50, BatteryState::Charging),
    ]);
    assert_eq!(plugged[0].linger, Linger::Brief);
}

#[test]
fn a_vpn_connecting_is_merely_good_news() {
    let sent = last(&[with_vpn(false, None), with_vpn(true, Some("NL#42"))]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].urgency, Urgency::Low);
    assert_eq!(sent[0].body, "Connected — NL#42");
}

#[test]
fn switching_vpn_server_names_the_new_one() {
    let sent = last(&[with_vpn(true, Some("NL#42")), with_vpn(true, Some("CH#7"))]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].body, "Now on CH#7");
}

#[test]
fn the_mail_bridge_stopping_is_reported() {
    let sent = last(&[with_bridge(true), with_bridge(false)]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Mail Bridge");
    assert_eq!(sent[0].urgency, Urgency::Normal);

    let back = last(&[with_bridge(true), with_bridge(false), with_bridge(true)]);
    assert_eq!(back.len(), 1);
    assert_eq!(back[0].urgency, Urgency::Low);
}

#[test]
fn a_low_battery_is_announced_on_arrival() {
    let sent = last(&[with_battery(8, BatteryState::Discharging)]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Battery critical");
    assert_eq!(sent[0].urgency, Urgency::Critical);
    assert_eq!(sent[0].value, Some(8));
}

#[test]
fn a_battery_crosses_each_threshold_once() {
    let low = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(18, BatteryState::Discharging),
    ]);
    assert_eq!(low.len(), 1);
    assert_eq!(low[0].summary, "Battery low");

    let same_band = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(18, BatteryState::Discharging),
        with_battery(15, BatteryState::Discharging),
    ]);
    assert!(same_band.is_empty());

    let critical = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(18, BatteryState::Discharging),
        with_battery(9, BatteryState::Discharging),
    ]);
    assert_eq!(critical.len(), 1);
    assert_eq!(critical[0].summary, "Battery critical");
}

#[test]
fn a_battery_on_the_charger_is_never_low() {
    let sent = last(&[
        with_battery(50, BatteryState::Charging),
        with_battery(8, BatteryState::Charging),
    ]);
    assert!(
        sent.is_empty(),
        "8% and climbing is not a warning, got {sent:?}"
    );
}

#[test]
fn unplugging_at_a_low_charge_warns_again() {
    let sent = last(&[
        with_battery(15, BatteryState::Discharging),
        with_battery(15, BatteryState::Charging),
        with_battery(15, BatteryState::Discharging),
    ]);

    // Two things happened at once: the charger came out, and the charge is back
    // in the band that charging had cleared.
    let summaries: Vec<&str> = sent
        .iter()
        .map(|notification| notification.summary.as_str())
        .collect();
    assert!(summaries.contains(&"Battery"), "got {summaries:?}");
    assert!(summaries.contains(&"Battery low"), "got {summaries:?}");
}

#[test]
fn the_charger_going_in_is_reported_but_not_on_arrival() {
    assert!(
        last(&[with_battery(50, BatteryState::Charging)]).is_empty(),
        "arriving plugged in is not an event"
    );

    let sent = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(50, BatteryState::Charging),
    ]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Battery");
    assert_eq!(sent[0].body, "Charging — 50%");
}

#[test]
fn the_thresholds_fire_on_the_threshold_itself() {
    // The comparison is `>=`, so the threshold value belongs to the worse band.
    // One character makes these `>` and the warning arrives a percent late,
    // which no other test would notice.
    let at_eighty = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 80)]),
    ]);
    assert_eq!(at_eighty.len(), 1, "80 is full, not nearly full");
    assert_eq!(at_eighty[0].urgency, Urgency::Normal);

    let just_under = last(&[
        with_disks(vec![disk("/home", 50)]),
        with_disks(vec![disk("/home", 79)]),
    ]);
    assert!(just_under.is_empty(), "79 is not yet worth saying");

    let at_ninety = last(&[
        with_disks(vec![disk("/home", 82)]),
        with_disks(vec![disk("/home", 90)]),
    ]);
    assert_eq!(at_ninety.len(), 1);
    assert_eq!(at_ninety[0].urgency, Urgency::Critical);

    // The battery bands run through the same function with the percentage
    // inverted, so their boundaries are worth pinning separately.
    let at_twenty = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(20, BatteryState::Discharging),
    ]);
    assert_eq!(at_twenty.len(), 1);
    assert_eq!(at_twenty[0].summary, "Battery low");

    let at_twentyone = last(&[
        with_battery(50, BatteryState::Discharging),
        with_battery(21, BatteryState::Discharging),
    ]);
    assert!(at_twentyone.is_empty());

    let at_ten = last(&[
        with_battery(18, BatteryState::Discharging),
        with_battery(10, BatteryState::Discharging),
    ]);
    assert_eq!(at_ten.len(), 1);
    assert_eq!(at_ten[0].summary, "Battery critical");
}

#[test]
fn a_battery_reaching_full_says_so() {
    let sent = last(&[
        with_battery(99, BatteryState::Charging),
        with_battery(100, BatteryState::Full),
    ]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Battery");
    assert_eq!(sent[0].body, "Fully charged");
}

#[test]
fn an_unknown_battery_state_is_not_worth_a_notification() {
    // sysfs is entitled to report something outside the set, and a ThinkPad in
    // conservation mode reports "Not charging" routinely. Announcing "Battery:
    // unknown" every time the kernel shrugged would be noise, so push_charger
    // returns without sending. A regression removing that early return would
    // otherwise pass every other test here.
    let sent = last(&[
        with_battery(60, BatteryState::Discharging),
        with_battery(60, BatteryState::Unknown),
    ]);
    assert!(sent.is_empty(), "got {sent:?}");
}

#[test]
fn a_camera_switching_on_names_what_opened_it() {
    let sent = last(&[with_cameras(&[]), with_cameras(&["zoom"])]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Camera in use");
    assert_eq!(sent[0].body, "Started by zoom");
}

#[test]
fn a_second_program_reaching_the_camera_is_also_news() {
    let sent = last(&[with_cameras(&["zoom"]), with_cameras(&["obs", "zoom"])]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].body, "Started by obs");
}

#[test]
fn the_camera_going_quiet_is_reported_once() {
    let sent = last(&[with_cameras(&["zoom"]), with_cameras(&[])]);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].summary, "Camera off");
    assert_eq!(sent[0].urgency, Urgency::Low);

    let still_quiet = last(&[
        with_cameras(&["zoom"]),
        with_cameras(&[]),
        with_cameras(&[]),
    ]);
    assert!(still_quiet.is_empty());
}

#[test]
fn a_tick_that_did_not_scan_cameras_is_not_a_camera_switching_off() {
    let mut state = State::new();
    advance(&mut state, &with_cameras(&["zoom"]));

    // `cameras: None`. This tick did not look. An empty Vec here would read as
    // "everything stopped" and fire a notification saying so.
    let skipped = advance(&mut state, &Observed::default());
    assert!(skipped.is_empty(), "got {skipped:?}");

    // And the remembered state survived the skip, so the next real scan still
    // sees zoom as already-running rather than as newly-started.
    let unchanged = advance(&mut state, &with_cameras(&["zoom"]));
    assert!(unchanged.is_empty(), "got {unchanged:?}");
}

#[test]
fn a_blind_first_tick_does_not_make_the_first_snapshot_look_like_a_change() {
    // The watcher's unit is only ordered After the status poller, not gated on
    // it having written anything, and a restart lands the next first tick
    // wherever it lands. So ticks with no snapshot at all come first in
    // practice, and a single "have I seen anything yet" flag would go true on
    // one of them while `network` was still None. The genuinely first snapshot
    // would then read as a reconnection.
    let mut state = State::new();
    let blind = advance(&mut state, &Observed::default());
    assert!(blind.is_empty());

    let first = advance(&mut state, &with_network(Some(wifi("home"))));
    assert!(
        first.is_empty(),
        "the watcher has still never seen a network; it arrived, it did not witness a connection. got {first:?}"
    );

    // And it has not gone deaf: a real change after that still speaks.
    let moved = advance(&mut state, &with_network(Some(wifi("cafe"))));
    assert_eq!(moved.len(), 1);
    assert_eq!(moved[0].body, "Now on cafe");
}

#[test]
fn a_blind_tick_does_not_make_the_first_camera_scan_look_like_a_change() {
    // Same fault, squared: camera scans run on one tick in five, so almost
    // every tick carries no scan. Sharing a flag with the snapshot gate would
    // make the first scan announce every program already using the camera.
    let mut state = State::new();
    advance(&mut state, &Observed::default());
    advance(&mut state, &with_network(Some(wifi("home"))));

    let first_scan = advance(&mut state, &with_cameras(&["zoom"]));
    assert!(
        first_scan.is_empty(),
        "zoom was already on the camera before anyone looked. got {first_scan:?}"
    );

    let started = advance(&mut state, &with_cameras(&["obs", "zoom"]));
    assert_eq!(started.len(), 1);
    assert_eq!(started[0].body, "Started by obs");
}

#[test]
fn a_missing_snapshot_reports_nothing_and_forgets_nothing() {
    let mut state = State::new();
    advance(&mut state, &with_network(Some(wifi("home"))));

    // The status poller stopped, or its snapshot went stale.
    let blind = advance(&mut state, &Observed::default());
    assert!(blind.is_empty());

    // When it comes back unchanged, that is still not a reconnection.
    let resumed = advance(&mut state, &with_network(Some(wifi("home"))));
    assert!(resumed.is_empty(), "got {resumed:?}");
}
