//! Wi-Fi setup via `NetworkManager`'s `nmcli` (the live ISO and the installed
//! system both run `NetworkManager`). Parsing is pure and unit-tested;
//! [`run_op`] executes on a worker thread streaming events back over mpsc,
//! mirroring `install::run`.

use std::collections::HashMap;
use std::sync::mpsc::Sender;

/// Events the network worker sends to the UI thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// Result of `nmcli networking connectivity check` — true only for "full".
    Connectivity(bool),
    ScanDone(Result<Vec<WifiNetwork>, String>),
    ConnectDone(Result<(), String>),
}

/// Operations the UI requests; `main()` runs each on a worker thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Scan,
    Connect {
        ssid: String,
        /// Transits argv as `nmcli device wifi connect <ssid> password
        /// <pw>` — acceptable on the single-user, root-only live ISO since
        /// nmcli has no non-interactive stdin alternative for this. On
        /// success `NetworkManager` persists the profile to
        /// /etc/NetworkManager/system-connections, which the install plan
        /// later copies to the target.
        password: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WifiNetwork {
    pub ssid: String,
    /// 0–100 as reported by nmcli.
    pub signal: u8,
    /// nmcli SECURITY column; empty or "--" means an open network.
    pub security: String,
}

impl WifiNetwork {
    #[must_use]
    pub fn is_open(&self) -> bool {
        self.security.is_empty() || self.security == "--"
    }

    #[must_use]
    pub fn signal_bars(&self) -> &'static str {
        match self.signal {
            0..=24 => "▂___",
            25..=49 => "▂▄__",
            50..=74 => "▂▄▆_",
            _ => "▂▄▆█",
        }
    }
}

/// Split a line of nmcli terse output on unescaped `:`, treating `\` as an
/// escape for the next character (so `\:` is a literal colon and `\\` a
/// literal backslash inside a field).
fn split_terse(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(next) = chars.next() {
                    current.push(next);
                }
            }
            ':' => fields.push(std::mem::take(&mut current)),
            _ => current.push(c),
        }
    }
    fields.push(current);
    fields
}

/// Parse the output of `nmcli -t -f SSID,SIGNAL,SECURITY device wifi list
/// --rescan yes`. Hidden networks (empty SSID) and malformed lines are
/// skipped; a network seen on multiple BSSIDs/bands is deduped, keeping the
/// strongest signal. Sorted by signal descending, ties by SSID ascending.
#[must_use]
pub fn parse_wifi_list(terse: &str) -> Vec<WifiNetwork> {
    let mut by_ssid: HashMap<String, WifiNetwork> = HashMap::new();
    for line in terse.lines() {
        let fields = split_terse(line);
        let [ssid, signal, security] = fields.as_slice() else {
            continue;
        };
        if ssid.is_empty() {
            continue;
        }
        let signal: u8 = signal.parse().unwrap_or(0);
        by_ssid
            .entry(ssid.clone())
            .and_modify(|n| {
                if signal > n.signal {
                    n.signal = signal;
                    n.security.clone_from(security);
                }
            })
            .or_insert_with(|| WifiNetwork {
                ssid: ssid.clone(),
                signal,
                security: security.clone(),
            });
    }
    let mut nets: Vec<WifiNetwork> = by_ssid.into_values().collect();
    nets.sort_by(|a, b| b.signal.cmp(&a.signal).then_with(|| a.ssid.cmp(&b.ssid)));
    nets
}

/// True iff `nmcli networking connectivity check` reports "full" — the only
/// state reliable enough for `nixos-install` to reach the binary cache.
#[must_use]
pub fn parse_connectivity(s: &str) -> bool {
    s.trim() == "full"
}

/// Run one network operation, sending progress/result events. Never panics;
/// all sends and subprocess failures are absorbed.
pub fn run_op(op: Op, tx: &Sender<Event>) {
    if std::env::var("DOTS_INSTALLER_DRY_RUN").is_ok() {
        run_dry(&op, tx);
        return;
    }
    run_real(op, tx);
}

fn run_dry(op: &Op, tx: &Sender<Event>) {
    match op {
        Op::Scan => {
            let _ = tx.send(Event::Connectivity(false));
            std::thread::sleep(std::time::Duration::from_millis(300));
            let _ = tx.send(Event::ScanDone(Ok(vec![
                WifiNetwork {
                    ssid: "tokyonight-cafe".into(),
                    signal: 82,
                    security: "WPA2".into(),
                },
                WifiNetwork {
                    ssid: "eduroam".into(),
                    signal: 61,
                    security: "WPA2 802.1X".into(),
                },
                WifiNetwork {
                    ssid: "guest-open".into(),
                    signal: 47,
                    security: String::new(),
                },
            ])));
        }
        Op::Connect { .. } => {
            std::thread::sleep(std::time::Duration::from_millis(500));
            let _ = tx.send(Event::ConnectDone(Ok(())));
        }
    }
}

fn run_real(op: Op, tx: &Sender<Event>) {
    match op {
        Op::Scan => run_scan(tx),
        Op::Connect { ssid, password } => run_connect(&ssid, password.as_deref(), tx),
    }
}

fn run_scan(tx: &Sender<Event>) {
    let online = std::process::Command::new("nmcli")
        .args(["networking", "connectivity", "check"])
        .output()
        .is_ok_and(|out| {
            out.status.success() && parse_connectivity(&String::from_utf8_lossy(&out.stdout))
        });
    let _ = tx.send(Event::Connectivity(online));

    let _ = std::process::Command::new("nmcli")
        .args(["radio", "wifi", "on"])
        .output();

    match std::process::Command::new("nmcli")
        .args([
            "-t",
            "-f",
            "SSID,SIGNAL,SECURITY",
            "device",
            "wifi",
            "list",
            "--rescan",
            "yes",
        ])
        .output()
    {
        Ok(out) if out.status.success() => {
            let _ = tx.send(Event::ScanDone(Ok(parse_wifi_list(
                &String::from_utf8_lossy(&out.stdout),
            ))));
        }
        Ok(out) => {
            let _ = tx.send(Event::ScanDone(Err(command_error(&out))));
        }
        Err(e) => {
            let _ = tx.send(Event::ScanDone(Err(e.to_string())));
        }
    }
}

fn run_connect(ssid: &str, password: Option<&str>, tx: &Sender<Event>) {
    let mut args = vec!["device", "wifi", "connect", ssid];
    if let Some(pw) = password {
        args.push("password");
        args.push(pw);
    }
    match std::process::Command::new("nmcli").args(&args).output() {
        Ok(out) if out.status.success() => {
            let _ = tx.send(Event::ConnectDone(Ok(())));
        }
        Ok(out) => {
            let _ = tx.send(Event::ConnectDone(Err(command_error(&out))));
        }
        Err(e) => {
            let _ = tx.send(Event::ConnectDone(Err(e.to_string())));
        }
    }
}

/// Trimmed stderr, falling back to the exit status when stderr is empty.
fn command_error(out: &std::process::Output) -> String {
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
    if stderr.is_empty() {
        format!("nmcli exited with {}", out.status)
    } else {
        stderr
    }
}
