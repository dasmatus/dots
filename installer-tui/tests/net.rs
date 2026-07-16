//! nmcli output parsing + Wi-Fi op contract tests.

use std::sync::mpsc;

use dots_installer::net::{parse_connectivity, parse_wifi_list, run_op, Event, Op, WifiNetwork};

#[test]
fn parse_wifi_list_sorts_by_signal_desc_ties_by_ssid_asc() {
    let terse = "b-net:40:WPA2\na-net:70:WPA2\nc-net:70:WPA2\n";
    let nets = parse_wifi_list(terse);
    assert_eq!(
        nets,
        vec![
            WifiNetwork {
                ssid: "a-net".into(),
                signal: 70,
                security: "WPA2".into()
            },
            WifiNetwork {
                ssid: "c-net".into(),
                signal: 70,
                security: "WPA2".into()
            },
            WifiNetwork {
                ssid: "b-net".into(),
                signal: 40,
                security: "WPA2".into()
            },
        ]
    );
}

#[test]
fn parse_wifi_list_handles_escaped_colon_in_ssid() {
    let nets = parse_wifi_list("home\\:net:72:WPA2\n");
    assert_eq!(
        nets,
        vec![WifiNetwork {
            ssid: "home:net".into(),
            signal: 72,
            security: "WPA2".into()
        }]
    );
}

#[test]
fn parse_wifi_list_handles_escaped_backslash_in_ssid() {
    let nets = parse_wifi_list("foo\\\\bar:50:WPA2\n");
    assert_eq!(
        nets,
        vec![WifiNetwork {
            ssid: "foo\\bar".into(),
            signal: 50,
            security: "WPA2".into()
        }]
    );
}

#[test]
fn parse_wifi_list_skips_hidden_and_dedupes_by_strongest_signal() {
    let terse = ":90:WPA2\nmulti-ap:35:WPA2\nmulti-ap:68:WPA2\n";
    let nets = parse_wifi_list(terse);
    assert_eq!(nets.len(), 1);
    assert_eq!(nets[0].ssid, "multi-ap");
    assert_eq!(nets[0].signal, 68);
}

#[test]
fn parse_wifi_list_ignores_malformed_lines_and_defaults_bad_signal_to_zero() {
    let terse = "too:few\ntoo:many:fields:here\ngood-net:not-a-number:WPA2\n";
    let nets = parse_wifi_list(terse);
    assert_eq!(
        nets,
        vec![WifiNetwork {
            ssid: "good-net".into(),
            signal: 0,
            security: "WPA2".into()
        }]
    );
}

#[test]
fn parse_connectivity_only_full_is_online() {
    assert!(parse_connectivity("full\n"));
    assert!(!parse_connectivity("limited"));
    assert!(!parse_connectivity("none"));
    assert!(!parse_connectivity("portal"));
    assert!(!parse_connectivity(""));
}

#[test]
fn is_open_recognizes_empty_and_dashes() {
    let open = WifiNetwork {
        ssid: "a".into(),
        signal: 50,
        security: String::new(),
    };
    let dashes = WifiNetwork {
        ssid: "b".into(),
        signal: 50,
        security: "--".into(),
    };
    let secured = WifiNetwork {
        ssid: "c".into(),
        signal: 50,
        security: "WPA2".into(),
    };
    assert!(open.is_open());
    assert!(dashes.is_open());
    assert!(!secured.is_open());
}

#[test]
fn signal_bars_quartile_boundaries() {
    let bars = |signal| {
        WifiNetwork {
            ssid: "x".into(),
            signal,
            security: String::new(),
        }
        .signal_bars()
    };
    assert_eq!(bars(0), "▂___");
    assert_eq!(bars(24), "▂___");
    assert_eq!(bars(25), "▂▄__");
    assert_eq!(bars(49), "▂▄__");
    assert_eq!(bars(50), "▂▄▆_");
    assert_eq!(bars(74), "▂▄▆_");
    assert_eq!(bars(75), "▂▄▆█");
    assert_eq!(bars(100), "▂▄▆█");
}

/// Scan and Connect are exercised in one test, not two: `DOTS_INSTALLER_DRY_RUN`
/// is process-global env state and cargo runs tests in parallel threads, so a
/// second test setting/clearing the same var would race this one.
#[test]
fn dry_run_contract_for_scan_and_connect() {
    std::env::set_var("DOTS_INSTALLER_DRY_RUN", "1");

    let (tx, rx) = mpsc::channel();
    run_op(Op::Scan, &tx);
    let events: Vec<Event> = rx.try_iter().collect();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0], Event::Connectivity(false));
    match &events[1] {
        Event::ScanDone(Ok(nets)) => assert_eq!(nets.len(), 3),
        other => panic!("expected ScanDone(Ok(_)), got {other:?}"),
    }

    let (tx, rx) = mpsc::channel();
    run_op(
        Op::Connect {
            ssid: "tokyonight-cafe".into(),
            password: Some("hunter22".into()),
        },
        &tx,
    );
    let events: Vec<Event> = rx.try_iter().collect();
    assert_eq!(events, vec![Event::ConnectDone(Ok(()))]);

    std::env::remove_var("DOTS_INSTALLER_DRY_RUN");
}
