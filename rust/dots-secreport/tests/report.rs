//! The security report's parsers, against fixtures captured from a real
//! machine, bad states included, because those are the ones that matter.
//!
//! Each parser takes text and returns a card, so none of this needs the
//! hardware it describes. The fixtures live in `tests/fixtures/` following
//! `rust/installer-tui/tests/fixtures/lsblk.json`.
//!
//! The load-bearing test here is `a_real_machine_never_reports_all_green`.
//! A dashboard that always reads clean teaches the reader to ignore it, so
//! "everything is fine" is the one result that must be impossible to produce
//! by accident on a host with known-bad state.

use std::fs;
use std::path::PathBuf;

use dots_secreport::report::{
    assemble, parse_active_captures, parse_apparmor, parse_cpu_vulnerabilities, parse_fido2,
    parse_fwupdmgr_security, parse_lockdown, parse_secure_boot, CaptureKind, Status,
};

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading fixture {}: {e}", path.display()))
}

/// Every `vulnerabilities/*` file as (name, contents), the shape
/// `parse_cpu_vulnerabilities` takes.
fn vulnerability_entries() -> Vec<(String, String)> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/vulnerabilities");
    let mut entries: Vec<(String, String)> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .map(|entry| {
            let entry = entry.expect("directory entry");
            let name = entry.file_name().to_string_lossy().into_owned();
            let contents = fs::read_to_string(entry.path()).expect("vulnerability file");
            (name, contents)
        })
        .collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    entries
}

#[test]
fn secure_boot_parses_as_disabled_from_real_bootctl_output() {
    let card = parse_secure_boot(&fixture("bootctl-status.txt"));

    assert_eq!(card.status, Status::Warn, "Secure Boot is off on this host");
    let detail = card.detail.to_lowercase();
    assert!(
        detail.contains("disabled"),
        "the detail must say Secure Boot is disabled, got: {}",
        card.detail
    );
}

#[test]
fn secure_boot_explains_that_being_off_is_this_repo_s_deliberate_choice() {
    // Secure Boot was removed from this repo in favour of TPM2 auto-unlock
    // (flake/apps.nix records it). A reader seeing "disabled" with no reason
    // would file it as a regression and go looking for the break.
    let card = parse_secure_boot(&fixture("bootctl-status.txt"));

    assert!(
        card.detail.contains("flake/apps.nix"),
        "the detail must point at where the decision is recorded, got: {}",
        card.detail
    );
}

#[test]
fn an_absent_lockdown_file_is_unavailable_and_never_disabled() {
    // The distinction this test exists for: `/sys/kernel/security/lockdown`
    // is missing here because the LSM is not compiled in. That is a different
    // fact from the feature being present and switched off, and reporting the
    // second when the first is true would be a lie the reader might act on.
    let card = parse_lockdown(None);

    // Assert on the status, not on the prose. The detail legitimately
    // contains the word "disabled" inside the phrase "this is unavailable,
    // not disabled", a denial, not a claim, so a substring check reads the
    // correct sentence as the bug it was written to prevent. The status is
    // what the page colours the card from, and it is the thing that must not
    // drift.
    assert_eq!(
        card.status,
        Status::Unavailable,
        "an absent lockdown file is unavailable, not a failure: {}",
        card.detail
    );
    assert_ne!(
        card.status,
        Status::Fail,
        "reporting absence as failure would send the reader hunting a break that is not there"
    );
    assert!(
        card.detail.to_lowercase().contains("not compiled")
            || card.detail.to_lowercase().contains("does not exist"),
        "the detail must explain why it is absent, got: {}",
        card.detail
    );
}

#[test]
fn a_present_lockdown_file_is_read_rather_than_assumed() {
    // The counterpart to the test above: when the file does exist, its
    // contents decide the card. Without this, "always unavailable" would pass
    // the absence test and be equally wrong.
    let card = parse_lockdown(Some("none [integrity] confidentiality\n"));

    assert_ne!(
        card.status,
        Status::Unavailable,
        "a readable lockdown file must not report as unavailable: {}",
        card.detail
    );
}

#[test]
fn a_missing_u2f_keys_file_reports_not_enrolled_with_the_fix() {
    let card = parse_fido2(Some(None));

    assert_eq!(card.status, Status::Warn);
    assert!(
        card.rows
            .iter()
            .any(|row| row.value.contains("enroll-fido")),
        "the card must name the command that fixes it, got rows: {:?}",
        card.rows
    );
}

#[test]
fn an_unreadable_apparmor_profile_count_degrades_instead_of_erroring() {
    // The profiles file is root-only. The whole report must not fail, and the
    // collector must not escalate privileges to read it. The card keeps the
    // enablement fact it can see and marks the count unavailable.
    let card = parse_apparmor(Some("Yes\n"), Err("permission denied"));

    // Warn, not Ok. This assertion used to demand Ok, and that was wrong in a
    // way this machine demonstrated: AppArmor was enabled with ZERO profiles
    // loaded, the LSM active, nothing confined, and the card reported Ok
    // the entire time, because enablement was all it checked. "I could not
    // check" must not render the same as "I checked and it is fine".
    assert_eq!(
        card.status,
        Status::Warn,
        "an unverifiable profile count cannot read as fine: {}",
        card.detail
    );
    assert!(
        card.rows
            .iter()
            .any(|row| row.value.to_lowercase().contains("unavailable")),
        "the count row must say it is unavailable, got rows: {:?}",
        card.rows
    );
}

#[test]
fn apparmor_enabled_with_zero_profiles_is_a_failure_not_an_ok() {
    // The state this machine was actually in: `security.apparmor.packages`
    // set (the include path) with no `policies`, so the generated unit tore
    // profiles down at boot and loaded none. `aa-enabled` answered "Yes" and
    // the profile list was empty.
    //
    // Fail rather than Warn on purpose. Switched on and confining nothing is
    // worse than switched off, because every surface, this dashboard
    // included, reports it as protection that exists.
    let card = parse_apparmor(Some("Yes\n"), Ok(0));

    assert_eq!(
        card.status,
        Status::Fail,
        "zero profiles means nothing is confined: {}",
        card.detail
    );
}

#[test]
fn apparmor_with_profiles_loaded_says_how_many() {
    // The counterpart: a real count is what earns Ok, and the number belongs
    // in the detail so the reader can see the claim rather than trust it.
    let card = parse_apparmor(Some("Yes\n"), Ok(223));

    assert_eq!(card.status, Status::Ok);
    assert!(
        card.detail.contains("223"),
        "the count is the evidence; show it: {}",
        card.detail
    );
}

#[test]
fn cpu_vulnerabilities_parse_real_mitigation_strings() {
    let card = parse_cpu_vulnerabilities(&vulnerability_entries());

    assert!(
        card.rows.len() >= 15,
        "this machine exposes ~19 attributes, got {}",
        card.rows.len()
    );
    assert!(
        card.rows
            .iter()
            .any(|row| row.value.starts_with("Mitigation")),
        "at least one attribute carries a real mitigation string"
    );
}

#[test]
fn the_firmware_card_surfaces_failing_attributes_from_real_fwupd_output() {
    let card = parse_fwupdmgr_security(&fixture("fwupdmgr-security.json"));

    assert_ne!(
        card.status,
        Status::Ok,
        "the captured host reports HSI-1 with failing checks: {}",
        card.detail
    );
    assert!(
        !card.rows.is_empty(),
        "failing attributes must be listed, not just counted"
    );
}

#[test]
fn assemble_orders_bad_cards_first() {
    // The page renders `cards` in order and adds no judgement of its own, so
    // the ordering is what makes it lead with problems.
    let cards = vec![
        parse_apparmor(Some("Yes\n"), Ok(42)),
        parse_lockdown(None),
        parse_secure_boot(&fixture("bootctl-status.txt")),
    ];

    let report = assemble(cards);
    let statuses: Vec<Status> = report.cards.iter().map(|card| card.status).collect();

    let mut sorted = statuses.clone();
    sorted.sort_by_key(|status| match status {
        Status::Fail => 0,
        Status::Warn => 1,
        Status::Unavailable => 2,
        Status::Ok => 3,
    });
    assert_eq!(statuses, sorted, "cards must come back worst-first");
}

#[test]
fn a_real_machine_never_reports_all_green() {
    // The honesty check. Fed this host's actual state: Secure Boot off,
    // no FIDO2 key enrolled, no lockdown LSM. The report must say so. If a
    // future refactor collapses `unavailable` into `ok`, or defaults an
    // unreadable source to "fine", this is what catches it.
    let cards = vec![
        parse_secure_boot(&fixture("bootctl-status.txt")),
        parse_fido2(Some(None)),
        parse_lockdown(None),
        parse_fwupdmgr_security(&fixture("fwupdmgr-security.json")),
        parse_cpu_vulnerabilities(&vulnerability_entries()),
    ];

    let report = assemble(cards);
    let clean = report.cards.iter().all(|card| card.status == Status::Ok);

    assert!(
        !clean,
        "an all-green report on a host with known-bad state is a bug: {:?}",
        report
            .cards
            .iter()
            .map(|card| (card.id, card.status))
            .collect::<Vec<_>>()
    );
}

// `parse_active_captures` carried a doc comment claiming `tests/report.rs`
// exercised it directly, and did not: these two fixtures existed
// (pw-dump-sample.json, pw-dump-active-capture.json) with nothing reading
// them. Added here rather than left as the salvage found them, since a
// public, documented-as-tested parser with zero actual tests is exactly
// the gap this crate's own honesty argument warns against.
#[test]
fn a_quiescent_pw_dump_has_no_active_captures() {
    let captures = parse_active_captures(&fixture("pw-dump-sample.json"));

    assert!(
        captures.is_empty(),
        "both nodes in this fixture are suspended, not running: {captures:?}"
    );
}

#[test]
fn pw_dump_distinguishes_audio_from_screen_capture() {
    let captures = parse_active_captures(&fixture("pw-dump-active-capture.json"));

    assert_eq!(
        captures.len(),
        2,
        "the fixture has two RUNNING capture streams (a Source/Sink pair \
         does not count as a capture): {captures:?}"
    );
    assert!(
        captures
            .iter()
            .any(|c| c.kind == CaptureKind::Audio && c.app == "Firefox"),
        "Firefox's Stream/Input/Audio node must surface as an audio capture: {captures:?}"
    );
    assert!(
        captures
            .iter()
            .any(|c| c.kind == CaptureKind::Screen && c.app == "OBS Studio"),
        "OBS's Stream/Input/Video node carries media.role=Screen, which must \
         classify as a screen capture rather than plain video: {captures:?}"
    );
}
