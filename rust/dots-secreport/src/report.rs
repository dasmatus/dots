//! `report --json`: the collector half of the privacy and hardware-security
//! dashboard. Every card here is gathered read-only and unprivileged. No
//! `pkexec`, no `sudo`, ever, for any of them. Every external command
//! is optional: a missing `fwupdmgr`, `bootctl`, `pw-dump` or `cryptsetup`
//! degrades that one card to [`Status::Unavailable`] rather than aborting
//! the whole report.
//!
//! The governing rule this module exists to enforce: report what is true,
//! including when it is bad, and never conflate *absent* with *off*. A
//! feature the kernel was never built with is `unavailable`; a feature the
//! kernel has but nobody turned on is a genuinely different fact, `warn`
//! or `fail`. Collapsing the two is exactly how a security dashboard
//! starts lying to the person reading it.
//!
//! Every card follows the same shape: a pure `parse_*` function that turns
//! already-captured text into a [`Card`], plus a thin gathering wrapper
//! that runs the real command or reads the real file and hands the result
//! to the pure function. Only the pure half is exercised by
//! `tests/report.rs`, against fixtures captured from a real machine. See
//! that file for why an all-green report is the one output this module is
//! not allowed to produce.

use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Milliseconds since the Unix epoch, for [`Report::generated_ms`]. This
/// used to come from the sandbox's own audit-log module
/// (`dots_sandbox::broker::now_ms`); inlined here since that crate no
/// longer exists and this is the only remaining caller.
fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

/// A card's at-a-glance severity. The QML page renders purely off this
/// field. It never re-derives a colour from `detail` text, so every
/// card must pick honestly among the four, and `unavailable` must never
/// stand in for `ok` just because nothing worse could be confirmed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Ok,
    Warn,
    Fail,
    Unavailable,
}

impl Status {
    /// Bad-first ordering: `assemble` sorts on this so a page that just
    /// renders `cards` in order already leads with the bad ones, per the
    /// brief. A dashboard that always reads all-green teaches the user to
    /// ignore it.
    const fn severity(self) -> u8 {
        match self {
            Self::Fail => 0,
            Self::Warn => 1,
            Self::Unavailable => 2,
            Self::Ok => 3,
        }
    }
}

/// One structured line inside a [`Card`], a label/value pair the page can
/// lay out in a list without any card-specific rendering logic.
#[derive(Debug, Clone, Serialize)]
pub struct Row {
    pub label: String,
    pub value: String,
}

impl Row {
    fn new(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            value: value.into(),
        }
    }
}

/// One card of the dashboard: a title, a status the page trusts blindly,
/// a one-line human summary, and whatever structured rows back it up.
#[derive(Debug, Clone, Serialize)]
pub struct Card {
    pub id: &'static str,
    pub title: &'static str,
    pub status: Status,
    pub detail: String,
    pub rows: Vec<Row>,
}

impl Card {
    fn unavailable(id: &'static str, title: &'static str, detail: impl Into<String>) -> Self {
        Self {
            id,
            title,
            status: Status::Unavailable,
            detail: detail.into(),
            rows: Vec::new(),
        }
    }
}

/// The full dashboard document: one JSON object, `cards` already sorted
/// bad-first, so the QML page is a pure renderer with no logic of its own.
#[derive(Debug, Serialize)]
pub struct Report {
    pub generated_ms: u128,
    pub cards: Vec<Card>,
}

/// Sorts `cards` bad-first (stable, so cards tied on severity keep the
/// order they were gathered in) and wraps them with a generation
/// timestamp. Split out from [`collect`] so tests can build a [`Report`]
/// straight from hand-assembled cards without shelling out to anything.
#[must_use]
pub fn assemble(mut cards: Vec<Card>) -> Report {
    cards.sort_by_key(|card| card.status.severity());
    Report {
        generated_ms: now_ms(),
        cards,
    }
}

/// Gathers every card from the real machine and assembles the report.
/// This is the only function in this module that touches a process, a
/// file or the clock directly. Everything it calls out to is optional,
/// per the module doc comment, so no single missing tool can take the
/// whole report down with it.
#[must_use]
pub fn collect() -> Report {
    assemble(vec![
        firmware_security_card(),
        tpm_card(),
        iommu_card(),
        cpu_vulnerabilities_card(),
        secure_boot_card(),
        fido2_card(),
        kernel_lockdown_card(),
        apparmor_card(),
        disk_encryption_card(),
        mic_camera_card(),
        screen_capture_card(),
    ])
}

/// Runs `cmd args...` and returns its stdout whenever the process actually
/// started, regardless of its exit code. Several of the tools this module
/// shells out to (`bootctl status` on this very machine, for one) exit
/// non-zero over an unrelated failure, an unreadable `/boot`, while
/// still printing the one line this module actually needs on stdout
/// first. Discarding that output over an unrelated non-zero exit would
/// turn a present, working fact into a false `unavailable`. Only a spawn
/// failure (the binary is not on `PATH` at all) yields `None`, which is
/// the one case that should degrade the card.
fn run_stdout(cmd: &str, args: &[&str]) -> Option<String> {
    Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
}

// ---------------------------------------------------------------------
// Firmware security (`fwupdmgr security --json`)
// ---------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct FwupdSecurityDoc {
    #[serde(rename = "SecurityAttributes")]
    attributes: Vec<FwupdAttribute>,
}

#[derive(Debug, Deserialize)]
struct FwupdAttribute {
    #[serde(rename = "AppstreamId")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
    #[serde(rename = "HsiLevel")]
    level: Option<u32>,
    #[serde(rename = "HsiResult")]
    result: Option<String>,
    #[serde(rename = "HsiResultSuccess")]
    result_success: Option<String>,
}

impl FwupdAttribute {
    /// An attribute "passes" only when its actual result matches the
    /// result `fwupd` itself defines as success. A missing `HsiResult` (as
    /// `org.fwupd.hsi.Kernel.Lockdown` has on this machine, see its
    /// `missing-data` flag) can never be confirmed passing, so it counts
    /// as failing rather than being silently skipped.
    fn passes(&self) -> bool {
        matches!((&self.result, &self.result_success), (Some(r), Some(s)) if r == s)
    }
}

/// Excluded by `AppstreamId`: both of these are already their own card,
/// fed from a more direct source (`bootctl status`, `/sys/kernel/security
/// /lockdown`) than `fwupd`'s own HSI heuristic for them. Folding them
/// into this card's number too risks two cards quoting two different
/// numbers for the same fact, which is its own way of teaching the reader
/// not to trust the dashboard.
const FWUPD_EXCLUDED_IDS: [&str; 2] = [
    "org.fwupd.hsi.Uefi.SecureBoot",
    "org.fwupd.hsi.Kernel.Lockdown",
];

/// Parses `fwupdmgr security --json` and reconstructs the Host Security ID
/// level `fwupdmgr security` (no `--json`) prints as `HSI:N`: the highest
/// level `N` such that every leveled, non-excluded attribute at or below
/// `N` passes. Confirmed against this machine's own `fwupdmgr security`
/// output (`HSI:1!`, two failing HSI-2 attributes) rather than guessed at.
#[must_use]
pub fn parse_fwupdmgr_security(json: &str) -> Card {
    let doc: FwupdSecurityDoc = match serde_json::from_str(json) {
        Ok(doc) => doc,
        Err(err) => {
            return Card::unavailable(
                "firmware_security",
                "Firmware security",
                format!("fwupdmgr security --json did not parse: {err}"),
            );
        }
    };

    let leveled: Vec<&FwupdAttribute> = doc
        .attributes
        .iter()
        .filter(|a| a.level.is_some() && !FWUPD_EXCLUDED_IDS.contains(&a.id.as_str()))
        .collect();
    let max_level = leveled.iter().filter_map(|a| a.level).max().unwrap_or(0);

    let mut achieved = 0;
    for level in 1..=max_level {
        let all_pass = leveled
            .iter()
            .filter(|a| a.level == Some(level))
            .all(|a| a.passes());
        if all_pass {
            achieved = level;
        } else {
            break;
        }
    }

    let failing: Vec<&FwupdAttribute> = leveled.iter().filter(|a| !a.passes()).copied().collect();
    let status = if failing.is_empty() {
        Status::Ok
    } else {
        Status::Warn
    };
    let rows = failing
        .iter()
        .map(|a| {
            Row::new(
                a.name.clone(),
                a.result.clone().unwrap_or_else(|| "no data".to_string()),
            )
        })
        .collect();

    Card {
        id: "firmware_security",
        title: "Firmware security",
        status,
        detail: format!(
            "Host Security ID HSI-{achieved} ({} of {} checks failing)",
            failing.len(),
            leveled.len()
        ),
        rows,
    }
}

fn firmware_security_card() -> Card {
    match run_stdout("fwupdmgr", &["security", "--json"]) {
        Some(json) => parse_fwupdmgr_security(&json),
        None => Card::unavailable(
            "firmware_security",
            "Firmware security",
            "fwupdmgr is not installed",
        ),
    }
}

// ---------------------------------------------------------------------
// TPM / IOMMU: both are "does this sysfs class directory have entries",
// so one parser serves both cards.
// ---------------------------------------------------------------------

/// Parses a listing of `/sys/class/tpm/` or `/sys/class/iommu/` (already
/// read by the caller, `None` meaning the directory does not exist at
/// all). An empty-but-present directory and a wholly absent one are both
/// real, distinct facts worth telling apart in `detail`, even though
/// today's page only needs the status colour.
fn parse_sysfs_class_dir(
    id: &'static str,
    title: &'static str,
    noun: &str,
    entries: Option<Vec<String>>,
) -> Card {
    match entries {
        None => Card::unavailable(id, title, format!("no {noun} sysfs class on this kernel")),
        Some(names) if names.is_empty() => Card {
            id,
            title,
            status: Status::Warn,
            detail: format!("no {noun} device found"),
            rows: Vec::new(),
        },
        Some(names) => Card {
            id,
            title,
            status: Status::Ok,
            detail: format!("{} {noun} device(s) found", names.len()),
            rows: names.into_iter().map(|n| Row::new("device", n)).collect(),
        },
    }
}

fn list_sysfs_class(path: &Path) -> Option<Vec<String>> {
    let mut names: Vec<String> = std::fs::read_dir(path)
        .ok()?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    Some(names)
}

fn tpm_card() -> Card {
    parse_sysfs_class_dir(
        "tpm",
        "TPM",
        "TPM",
        list_sysfs_class(Path::new("/sys/class/tpm")),
    )
}

fn iommu_card() -> Card {
    parse_sysfs_class_dir(
        "iommu",
        "IOMMU / DMA protection",
        "IOMMU",
        list_sysfs_class(Path::new("/sys/class/iommu")),
    )
}

// ---------------------------------------------------------------------
// CPU vulnerability mitigations
// ---------------------------------------------------------------------

/// One `/sys/devices/system/cpu/vulnerabilities/*` file, parsed for both
/// facts it carries: whether the CPU is affected at all, and which
/// mitigation (if any) is in use, rather than just string-matching
/// `"Mitigation"` and calling it done.
#[derive(Debug, Clone, PartialEq, Eq)]
struct VulnerabilityStatus {
    name: String,
    vulnerable: bool,
    mitigation: Option<String>,
    raw: String,
}

fn parse_vulnerability_line(name: &str, raw: &str) -> VulnerabilityStatus {
    let trimmed = raw.trim();
    // The kernel's own vocabulary: a bare "Not affected" is the only
    // string that means the CPU was never vulnerable in the first place;
    // everything else ("Vulnerable", "Mitigation: ...", and compound
    // strings like spectre_v2's) means the kernel considered this CPU
    // affected, whether or not it found a mitigation to apply.
    let vulnerable = trimmed != "Not affected";
    let mitigation = trimmed.strip_prefix("Mitigation: ").map(|rest| {
        // Compound lines (spectre_v2) pack several ';'-separated facts
        // into one file; the primary mitigation name is the first.
        rest.split(';').next().unwrap_or(rest).trim().to_string()
    });
    VulnerabilityStatus {
        name: name.to_string(),
        vulnerable,
        mitigation,
        raw: trimmed.to_string(),
    }
}

/// Parses a captured tree of `/sys/devices/system/cpu/vulnerabilities/*`
/// files (name, contents pairs, sorted by the caller for deterministic
/// output). A CPU is only reported bad here when the kernel says so with
/// no mitigation applied at all (a bare `"Vulnerable"`); an affected CPU
/// with a mitigation in place is the expected, healthy state these files
/// exist to confirm.
#[must_use]
pub fn parse_cpu_vulnerabilities(entries: &[(String, String)]) -> Card {
    if entries.is_empty() {
        return Card::unavailable(
            "cpu_vulnerabilities",
            "CPU vulnerability mitigations",
            "no vulnerabilities sysfs tree on this kernel",
        );
    }
    let parsed: Vec<VulnerabilityStatus> = entries
        .iter()
        .map(|(name, raw)| parse_vulnerability_line(name, raw))
        .collect();
    let unmitigated: Vec<&VulnerabilityStatus> = parsed
        .iter()
        .filter(|v| v.vulnerable && v.mitigation.is_none())
        .collect();
    let status = if unmitigated.is_empty() {
        Status::Ok
    } else {
        Status::Fail
    };
    let rows = parsed
        .iter()
        .map(|v| Row::new(v.name.clone(), v.raw.clone()))
        .collect();
    Card {
        id: "cpu_vulnerabilities",
        title: "CPU vulnerability mitigations",
        status,
        detail: format!(
            "{} known issue(s) checked, {} unmitigated",
            parsed.len(),
            unmitigated.len()
        ),
        rows,
    }
}

fn cpu_vulnerabilities_card() -> Card {
    let dir = Path::new("/sys/devices/system/cpu/vulnerabilities");
    let Ok(read_dir) = std::fs::read_dir(dir) else {
        return Card::unavailable(
            "cpu_vulnerabilities",
            "CPU vulnerability mitigations",
            "no vulnerabilities sysfs tree on this kernel",
        );
    };
    let mut entries: Vec<(String, String)> = read_dir
        .filter_map(std::result::Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let contents = std::fs::read_to_string(entry.path()).ok()?;
            Some((name, contents))
        })
        .collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    parse_cpu_vulnerabilities(&entries)
}

// ---------------------------------------------------------------------
// Secure Boot (`bootctl status`)
// ---------------------------------------------------------------------

/// Parses `bootctl status` for its `Secure Boot: <state>` line. Reports
/// the raw hardware/firmware fact exactly as `bootctl` gives it. This
/// repo's own `flake/apps.nix` and `nix/README.md` record that Secure Boot
/// was deliberately removed (the `LiveISO` and the installed system both
/// boot plain/unsigned), so `disabled` is the *expected* reading here, but
/// that context belongs to whoever reads this card, not to this parser:
/// editorializing a bad status into a green one here is exactly the
/// failure mode this whole dashboard exists to catch.
#[must_use]
pub fn parse_secure_boot(bootctl_status: &str) -> Card {
    let line = bootctl_status
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("Secure Boot:"));
    match line.map(str::trim) {
        Some("enabled") => Card {
            id: "secure_boot",
            title: "Secure Boot",
            status: Status::Ok,
            detail: "Secure Boot is enabled".to_string(),
            rows: Vec::new(),
        },
        Some(other) => Card {
            id: "secure_boot",
            title: "Secure Boot",
            status: Status::Warn,
            detail: format!(
                "Secure Boot is {other}; this repo boots a plain, unsigned image by design \
                 (Secure Boot support was removed, see flake/apps.nix), so this reading is \
                 expected here, not a defect to silently fix"
            ),
            rows: Vec::new(),
        },
        None => Card::unavailable(
            "secure_boot",
            "Secure Boot",
            "bootctl status did not report a Secure Boot line",
        ),
    }
}

fn secure_boot_card() -> Card {
    match run_stdout("bootctl", &["status"]) {
        Some(status) => parse_secure_boot(&status),
        None => Card::unavailable("secure_boot", "Secure Boot", "bootctl is not installed"),
    }
}

// ---------------------------------------------------------------------
// FIDO2 second factor (`~/.config/Yubico/u2f_keys`)
// ---------------------------------------------------------------------

/// Parses the presence (or absence) of `~/.config/Yubico/u2f_keys`, one
/// non-blank line per enrolled key. `None` distinguishes "the file's
/// permissions could not even be checked" (a filesystem oddity worth its
/// own `unavailable`) from `Some(None)`, "checked and the file is not
/// there" (not enrolled, actionable, not merely unknown).
#[must_use]
pub fn parse_fido2(u2f_keys: Option<Option<&str>>) -> Card {
    match u2f_keys {
        None => Card::unavailable(
            "fido2",
            "FIDO2 second factor",
            "could not check for ~/.config/Yubico/u2f_keys",
        ),
        Some(None) => Card {
            id: "fido2",
            title: "FIDO2 second factor",
            status: Status::Warn,
            detail: "no FIDO2/U2F key enrolled as a second factor".to_string(),
            rows: vec![Row::new("fix", "nix run .#enroll-fido")],
        },
        Some(Some(contents)) => {
            let keys = contents.lines().filter(|l| !l.trim().is_empty()).count();
            Card {
                id: "fido2",
                title: "FIDO2 second factor",
                status: Status::Ok,
                detail: format!("{keys} FIDO2/U2F key(s) enrolled"),
                rows: Vec::new(),
            }
        }
    }
}

fn fido2_card() -> Card {
    let Some(home) = std::env::var_os("HOME") else {
        return Card::unavailable(
            "fido2",
            "FIDO2 second factor",
            "cannot resolve ~/.config/Yubico/u2f_keys: $HOME is not set",
        );
    };
    let path = PathBuf::from(home).join(".config/Yubico/u2f_keys");
    let reading = match std::fs::read_to_string(&path) {
        Ok(contents) => Some(Some(contents)),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Some(None),
        Err(_) => None,
    };
    parse_fido2(reading.as_ref().map(|inner| inner.as_deref()))
}

// ---------------------------------------------------------------------
// Kernel lockdown (`/sys/kernel/security/lockdown`)
// ---------------------------------------------------------------------

/// Parses `/sys/kernel/security/lockdown`'s bracketed-current-mode format
/// (`none [integrity] confidentiality`). `None` means the file does not
/// exist. The lockdown LSM is not compiled into this kernel at all,
/// which is `unavailable`, a different fact from the mode being present
/// but set to `none` (`warn`: the feature exists and is simply off).
#[must_use]
pub fn parse_lockdown(contents: Option<&str>) -> Card {
    let Some(contents) = contents else {
        return Card::unavailable(
            "kernel_lockdown",
            "Kernel lockdown",
            "/sys/kernel/security/lockdown does not exist: the lockdown LSM is not compiled \
             into this kernel (or not enabled via the security= boot parameter) — this is \
             unavailable, not disabled",
        );
    };
    let current = contents
        .split_whitespace()
        .find_map(|word| word.strip_prefix('[')?.strip_suffix(']'));
    match current {
        Some("none") => Card {
            id: "kernel_lockdown",
            title: "Kernel lockdown",
            status: Status::Warn,
            detail: "kernel lockdown is available but set to \"none\" (not engaged)".to_string(),
            rows: Vec::new(),
        },
        Some(mode @ ("integrity" | "confidentiality")) => Card {
            id: "kernel_lockdown",
            title: "Kernel lockdown",
            status: Status::Ok,
            detail: format!("kernel lockdown is engaged in \"{mode}\" mode"),
            rows: Vec::new(),
        },
        _ => Card::unavailable(
            "kernel_lockdown",
            "Kernel lockdown",
            format!("could not parse lockdown mode from {contents:?}"),
        ),
    }
}

fn kernel_lockdown_card() -> Card {
    let contents = std::fs::read_to_string("/sys/kernel/security/lockdown").ok();
    parse_lockdown(contents.as_deref())
}

// ---------------------------------------------------------------------
// AppArmor (`aa-enabled` for enablement, `/sys/kernel/security/apparmor
// /profiles` for a loaded-profile count, root-only, degrades rather than
// escalating)
// ---------------------------------------------------------------------

/// Parses `aa-enabled`'s stdout (`"Yes"`/`"No"`, whatever its exit code,
/// some `AppArmor` builds exit non-zero for "No") together with a
/// separately-gathered profile count. `profiles` is `Err` whenever that
/// read failed for any reason (typically `EPERM`: the profile list needs
/// `CAP_MAC_ADMIN`, confirmed on this machine even though the file's own
/// permission bits read `r--r--r--`). The card still reports enablement
/// in that case rather than erroring out entirely; only the one row that
/// needed a privileged read degrades.
#[must_use]
pub fn parse_apparmor(enabled_stdout: Option<&str>, profiles: Result<usize, &str>) -> Card {
    let Some(enabled_stdout) = enabled_stdout else {
        return Card::unavailable("apparmor", "AppArmor", "aa-enabled is not installed");
    };
    let enabled = enabled_stdout.trim().eq_ignore_ascii_case("yes");
    if !enabled {
        return Card {
            id: "apparmor",
            title: "AppArmor",
            status: Status::Warn,
            detail: "AppArmor is not enabled".to_string(),
            rows: Vec::new(),
        };
    }
    // Enabled is not the same as confining, and this card used to conflate
    // them. It reported `ok` / "AppArmor is enabled" on a machine where
    // /sys/kernel/security/apparmor/profiles held ZERO entries. The LSM was
    // active and nothing whatsoever was confined, and every surface said the
    // protection was on. The cause was a config that set
    // `security.apparmor.packages` (the include path) but no `policies`, so
    // the generated unit tore profiles down at boot and loaded none.
    //
    // So enablement alone never earns `ok` here:
    //
    // - a known count of zero is a real failure, not a warning: AppArmor is
    //   switched on and protecting nothing, which is worse than off because it
    //   reads as protection;
    // - an unknown count cannot be `ok` either. The profile list needs a
    //   privileged read this collector will not make, and "I could not check"
    //   must not render the same as "I checked and it is fine". That is the
    //   whole reason `unavailable` exists as a status distinct from `ok`.
    match profiles {
        Ok(0) => Card {
            id: "apparmor",
            title: "AppArmor",
            status: Status::Fail,
            detail: "AppArmor is enabled but has zero profiles loaded, so it is confining nothing"
                .to_string(),
            rows: vec![Row::new("loaded profiles", "0")],
        },
        Ok(count) => Card {
            id: "apparmor",
            title: "AppArmor",
            status: Status::Ok,
            detail: format!("AppArmor is enabled with {count} profile(s) loaded"),
            rows: vec![Row::new("loaded profiles", count.to_string())],
        },
        Err(reason) => Card {
            id: "apparmor",
            title: "AppArmor",
            status: Status::Warn,
            detail: "AppArmor is enabled, but whether any profiles are loaded could not be \
                     verified without a privileged read — enabled with nothing loaded confines \
                     nothing"
                .to_string(),
            rows: vec![Row::new(
                "loaded profiles",
                format!("unavailable ({reason}; requires a privileged read)"),
            )],
        },
    }
}

fn apparmor_card() -> Card {
    let enabled_stdout = run_stdout("aa-enabled", &[]);
    let profiles = match std::fs::read_to_string("/sys/kernel/security/apparmor/profiles") {
        Ok(text) => Ok(text.lines().filter(|l| !l.trim().is_empty()).count()),
        Err(err) if err.kind() == io::ErrorKind::PermissionDenied => Err("permission denied"),
        Err(_) => Err("not readable"),
    };
    parse_apparmor(enabled_stdout.as_deref(), profiles)
}

// ---------------------------------------------------------------------
// Disk encryption (`lsblk` for LUKS presence, `cryptsetup luksDump`,
// best-effort, never escalated to, for a TPM2 auto-unlock token)
// ---------------------------------------------------------------------

/// Walks an `lsblk -J` device tree (recursing through `children`) and
/// collects the `path` of every block device whose `fstype` is
/// `"crypto_LUKS"`. Pure over already-parsed JSON so the recursive-tree
/// walk is testable without a real block device.
#[must_use]
pub fn parse_lsblk_for_luks(json: &str) -> Vec<String> {
    let Ok(root) = serde_json::from_str::<Value>(json) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    let devices = root
        .get("blockdevices")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    collect_luks_paths(&devices, &mut found);
    found
}

fn collect_luks_paths(devices: &[Value], found: &mut Vec<String>) {
    for device in devices {
        if device.get("fstype").and_then(Value::as_str) == Some("crypto_LUKS") {
            if let Some(path) = device.get("path").and_then(Value::as_str) {
                found.push(path.to_string());
            }
        }
        if let Some(children) = device.get("children").and_then(Value::as_array) {
            collect_luks_paths(children, found);
        }
    }
}

fn disk_encryption_card() -> Card {
    let Some(json) = run_stdout(
        "lsblk",
        &["-J", "-o", "NAME,PATH,TYPE,FSTYPE,MOUNTPOINT,PKNAME"],
    ) else {
        return Card::unavailable(
            "disk_encryption",
            "Disk encryption",
            "lsblk is not installed",
        );
    };
    let luks_paths = parse_lsblk_for_luks(&json);
    if luks_paths.is_empty() {
        return Card {
            id: "disk_encryption",
            title: "Disk encryption",
            status: Status::Warn,
            detail: "no LUKS-encrypted block device found".to_string(),
            rows: Vec::new(),
        };
    }

    let mut rows = vec![Row::new("LUKS device(s)", luks_paths.join(", "))];
    // Best-effort only: `cryptsetup luksDump` needs read access to the raw
    // block device, which this uid does not have on this machine (no
    // `disk` group membership). That failure degrades this one row
    // rather than the card, and is never worked around with `sudo`.
    let tpm2_row = Command::new("cryptsetup")
        .args(["luksDump", &luks_paths[0]])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map_or_else(
            || "unavailable (requires privileged block-device read)".to_string(),
            |output| {
                let dump = String::from_utf8_lossy(&output.stdout);
                if dump.contains("systemd-tpm2") {
                    "yes".to_string()
                } else {
                    "no".to_string()
                }
            },
        );
    rows.push(Row::new("TPM2 auto-unlock", tpm2_row));

    Card {
        id: "disk_encryption",
        title: "Disk encryption",
        status: Status::Ok,
        detail: format!("{} LUKS-encrypted device(s) found", luks_paths.len()),
        rows,
    }
}

// ---------------------------------------------------------------------
// Microphone/camera and screen-capture, both read off the same `pw-dump`
// snapshot: PipeWire is the Wayland-era equivalent of the iOS green dot,
// naming exactly which client node holds an active capture stream right
// now. `xdg-desktop-portal`'s ScreenCast backend routes its frames through
// PipeWire too, tagged `media.role: "Screen"` on the stream node, so
// screen capture needs no second, D-Bus-based source: the same snapshot
// already carries both signals.
// ---------------------------------------------------------------------

/// Public so `tests/report.rs` can assert on `parse_active_captures`'s
/// output directly, the same way the rest of this module's pure parsers
/// are tested against captured text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureKind {
    Audio,
    Video,
    Screen,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveCapture {
    pub kind: CaptureKind,
    pub app: String,
}

/// Parses a `pw-dump` snapshot into the list of capture streams currently
/// `running` (as opposed to `idle`/`suspended`, `PipeWire`'s terms for a
/// stream that exists but isn't actively moving frames). Walks the node
/// graph via `serde_json` per the brief, rather than regexing the (large)
/// raw output.
#[must_use]
pub fn parse_active_captures(pw_dump_json: &str) -> Vec<ActiveCapture> {
    let Ok(Value::Array(objects)) = serde_json::from_str::<Value>(pw_dump_json) else {
        return Vec::new();
    };
    objects
        .iter()
        .filter_map(|obj| {
            let info = obj.get("info")?;
            if info.get("state").and_then(Value::as_str) != Some("running") {
                return None;
            }
            let props = info.get("props")?;
            let media_class = props.get("media.class").and_then(Value::as_str)?;
            let role = props.get("media.role").and_then(Value::as_str);
            let kind = match (media_class, role) {
                ("Stream/Input/Video", Some("Screen")) => CaptureKind::Screen,
                ("Stream/Input/Audio", _) => CaptureKind::Audio,
                ("Stream/Input/Video", _) => CaptureKind::Video,
                _ => return None,
            };
            let app = props
                .get("application.name")
                .and_then(Value::as_str)
                .or_else(|| props.get("node.name").and_then(Value::as_str))
                .unwrap_or("unknown app")
                .to_string();
            Some(ActiveCapture { kind, app })
        })
        .collect()
}

fn build_capture_card(
    id: &'static str,
    title: &'static str,
    captures: &[ActiveCapture],
    kinds: &[CaptureKind],
    noun: &str,
) -> Card {
    let matching: Vec<&ActiveCapture> = captures
        .iter()
        .filter(|c| kinds.contains(&c.kind))
        .collect();
    if matching.is_empty() {
        Card {
            id,
            title,
            status: Status::Ok,
            detail: format!("no {noun} capture active right now"),
            rows: Vec::new(),
        }
    } else {
        Card {
            id,
            title,
            status: Status::Warn,
            detail: format!("{} {noun} capture(s) active right now", matching.len()),
            rows: matching
                .iter()
                .map(|c| Row::new("held by", c.app.clone()))
                .collect(),
        }
    }
}

fn pw_dump_captures() -> Option<Vec<ActiveCapture>> {
    run_stdout("pw-dump", &[]).map(|json| parse_active_captures(&json))
}

fn mic_camera_card() -> Card {
    match pw_dump_captures() {
        // Mic and camera share one card. Either one active is equally
        // worth surfacing, and the row for each names which app holds it.
        Some(captures) => build_capture_card(
            "mic_camera",
            "Microphone / camera in use",
            &captures,
            &[CaptureKind::Audio, CaptureKind::Video],
            "microphone/camera",
        ),
        None => Card::unavailable(
            "mic_camera",
            "Microphone / camera in use",
            "pw-dump is not installed",
        ),
    }
}

fn screen_capture_card() -> Card {
    match pw_dump_captures() {
        Some(captures) => build_capture_card(
            "screen_capture",
            "Screen capture sessions",
            &captures,
            &[CaptureKind::Screen],
            "screen",
        ),
        None => Card::unavailable(
            "screen_capture",
            "Screen capture sessions",
            "pw-dump is not installed",
        ),
    }
}

// ---------------------------------------------------------------------
// The 24h capability-activity card that used to live here is gone with
// the sandbox it audited. `dots-sandbox`'s broker wrote
// `$XDG_STATE_HOME/dots-sandbox/audit.jsonl` on every capability
// request/grant/revoke; deleting `launch.rs`/`broker.rs` (see git history)
// means nothing writes that file again, ever. Keeping the card would mean
// a permanent, silently-frozen "no sandboxed app has logged any activity
// yet" — the exact "absent dressed up as fine" failure mode this whole
// module's own doc comment exists to forbid. Dropped rather than kept as
// dead weight; report.rs's own tests never exercised it (see git history's
// tests/report.rs), so nothing here loses coverage.
// ---------------------------------------------------------------------
