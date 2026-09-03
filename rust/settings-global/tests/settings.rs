//! Integration tests for the settings store: parsing the installer-written
//! /var/lib/dots/settings.nix format, lossless round-tripping (unknown keys
//! must survive), typed get/set, atomic save, and the field validators.

use global_settings::settings::{
    validate_git_email, validate_git_name, validate_hostname, validate_proton_email, Settings,
};

/// Verbatim shape of what rust/installer-tui/src/config.rs::settings_nix
/// writes on the target — the canonical on-disk format.
const INSTALLER_WRITTEN: &str = "{\n  username = \"matus\";\n  hostname = \"matthiasbuch\";\n  disks = [ \"/dev/nvme0n1\" ];\n  swapSize = \"15G\";\n  gitName = \"Ada Lovelace\";\n  gitEmail = \"ada@example.com\";\n  aiClaude = true;\n  aiCodex = false;\n  aiOllama = true;\n}\n";

#[test]
fn parses_installer_written_settings() {
    let s = Settings::parse(INSTALLER_WRITTEN).expect("canonical file must parse");
    assert_eq!(s.get_str("username").as_deref(), Some("matus"));
    assert_eq!(s.get_str("hostname").as_deref(), Some("matthiasbuch"));
    assert_eq!(s.get_str("gitName").as_deref(), Some("Ada Lovelace"));
    assert_eq!(s.get_bool("aiClaude"), Some(true));
    assert_eq!(s.get_bool("aiCodex"), Some(false));
    assert_eq!(s.get_bool("aiOllama"), Some(true));
}

#[test]
fn render_roundtrips_canonical_file_byte_for_byte() {
    let s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    assert_eq!(s.render(), INSTALLER_WRITTEN);
}

#[test]
fn preserves_unknown_keys_and_order_across_edit() {
    let mut s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    s.set_bool("aiClaude", false);
    let out = s.render();
    // Keys the CLI does not know about must survive an edit verbatim.
    assert!(out.contains("  disks = [ \"/dev/nvme0n1\" ];\n"));
    assert!(out.contains("  swapSize = \"15G\";\n"));
    assert!(out.contains("  username = \"matus\";\n"));
    assert!(out.contains("  aiClaude = false;\n"));
    // Order preserved: username stays first, aiOllama last.
    let keys: Vec<&str> = out
        .lines()
        .filter_map(|l| l.trim().split_once(" = "))
        .map(|(k, _)| k)
        .collect();
    assert_eq!(
        keys,
        [
            "username", "hostname", "disks", "swapSize", "gitName", "gitEmail", "aiClaude",
            "aiCodex", "aiOllama"
        ]
    );
}

#[test]
fn set_str_escapes_and_roundtrips_special_characters() {
    let mut s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    let tricky = "Ma\"tus \\ the ; first = second";
    s.set_str("gitName", tricky);
    let reparsed = Settings::parse(&s.render()).expect("escaped output must reparse");
    assert_eq!(reparsed.get_str("gitName").as_deref(), Some(tricky));
}

#[test]
fn set_str_escapes_nix_interpolation_so_values_are_inert() {
    let mut s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    let payload = "${builtins.readFile /etc/passwd}";
    s.set_str("gitName", payload);
    let out = s.render();
    // The `${` must be backslash-escaped so the flake reads a literal string,
    // never a live interpolation evaluated as root on the next rebuild.
    assert!(out.contains("\\${builtins"), "not escaped: {out}");
    assert!(
        !out.contains("\"${builtins"),
        "raw interpolation emitted: {out}"
    );
    // ...and it still round-trips back to the exact typed value.
    let reparsed = Settings::parse(&out).unwrap();
    assert_eq!(reparsed.get_str("gitName").as_deref(), Some(payload));
}

#[test]
fn parse_rejects_duplicate_keys() {
    let err = Settings::parse("{\n  hostname = \"a\";\n  hostname = \"b\";\n}\n")
        .expect_err("a duplicate binding is invalid Nix and must be rejected");
    assert!(err.to_string().contains("hostname"), "{err}");
}

#[test]
fn save_removes_tmp_file_when_rename_fails() {
    // Target is an existing directory, so the rename onto it fails; the
    // sibling `.tmp` must not be left next to it.
    let dir = std::env::temp_dir().join(format!("settings-savefail-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    assert!(s.save(&dir).is_err());
    let mut tmp = dir.clone().into_os_string();
    tmp.push(".tmp");
    assert!(
        !std::path::Path::new(&tmp).exists(),
        "tmp file left behind after failed rename"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn set_on_missing_key_appends_entry() {
    let mut s = Settings::parse("{\n  hostname = \"x\";\n}\n").unwrap();
    s.set_bool("aiClaude", true);
    let reparsed = Settings::parse(&s.render()).unwrap();
    assert_eq!(reparsed.get_bool("aiClaude"), Some(true));
    assert_eq!(reparsed.get_str("hostname").as_deref(), Some("x"));
}

#[test]
fn get_bool_is_none_for_non_bool_and_missing_keys() {
    let s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    assert_eq!(s.get_bool("gitName"), None);
    assert_eq!(s.get_bool("nope"), None);
}

#[test]
fn get_str_is_none_for_unquoted_values() {
    let s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    assert_eq!(s.get_str("aiClaude"), None);
    assert_eq!(s.get_str("disks"), None);
}

#[test]
fn parse_reports_line_number_for_garbage() {
    let err = Settings::parse("{\n  hostname = \"x\";\n  what is this\n}\n")
        .expect_err("non-binding line must be rejected");
    assert!(
        err.to_string().contains('3'),
        "error should name line 3: {err}"
    );
}

#[test]
fn parse_joins_multiline_list_values() {
    let src = "{\n  bootKernelParams = [\n    \"quiet\"\n    \"loglevel=3\"\n  ];\n  aiClaude = true;\n}\n";
    let s = Settings::parse(src).expect("multi-line list must parse");
    assert_eq!(s.get_bool("aiClaude"), Some(true));
    let out = s.render();
    let reparsed = Settings::parse(&out).unwrap();
    assert!(reparsed
        .get_raw("bootKernelParams")
        .unwrap()
        .contains("\"quiet\""));
    assert!(reparsed
        .get_raw("bootKernelParams")
        .unwrap()
        .contains("\"loglevel=3\""));
}

#[test]
fn save_and_load_roundtrip_via_file() {
    let path = std::env::temp_dir().join(format!("settings-test-{}.nix", std::process::id()));
    let mut s = Settings::parse(INSTALLER_WRITTEN).unwrap();
    s.set_str("hostname", "renamed");
    s.save(&path).expect("save must succeed in temp dir");
    let loaded = Settings::load(&path).expect("load must succeed");
    assert_eq!(loaded, s);
    assert_eq!(loaded.get_str("hostname").as_deref(), Some("renamed"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn load_missing_file_is_an_error_not_a_panic() {
    let err = Settings::load(std::path::Path::new("/nonexistent/settings.nix"))
        .expect_err("missing file must be a returned error");
    assert!(!err.to_string().is_empty());
}

#[test]
fn hostname_validator_mirrors_installer_rules() {
    assert!(validate_hostname("matthiasbuch").is_ok());
    assert!(validate_hostname("a-1").is_ok());
    assert!(validate_hostname("").is_err());
    assert!(validate_hostname("-lead").is_err());
    assert!(validate_hostname("trail-").is_err());
    assert!(validate_hostname("UpperCase").is_err());
    assert!(validate_hostname(&"x".repeat(64)).is_err());
}

#[test]
fn git_name_validator_rejects_empty_and_newlines() {
    assert!(validate_git_name("Ada Lovelace").is_ok());
    assert!(validate_git_name("").is_err());
    assert!(validate_git_name("  ").is_err());
    assert!(validate_git_name("a\nb").is_err());
}

#[test]
fn git_email_validator_mirrors_installer_rules() {
    assert!(validate_git_email("a@b.com").is_ok());
    assert!(validate_git_email("").is_err());
    assert!(validate_git_email("nodomain").is_err());
    assert!(validate_git_email("a@b").is_err());
    assert!(validate_git_email("a@@b.com").is_err());
    assert!(validate_git_email("a b@c.com").is_err());
}

#[test]
fn proton_email_validator_applies_the_same_rules() {
    assert!(validate_proton_email("a@b.com").is_ok());
    assert!(validate_proton_email("").is_err());
    assert!(validate_proton_email("nodomain").is_err());
    assert!(validate_proton_email("a@b").is_err());
    assert!(validate_proton_email("a@@b.com").is_err());
    assert!(validate_proton_email("a b@c.com").is_err());
}

/// The two callers share one checker, so the only thing separating their
/// messages is the label. Pinning both sides stops a future refactor from
/// quietly reporting "git email" on the Proton row.
#[test]
fn email_validators_name_the_field_they_rejected() {
    assert!(validate_git_email("nodomain")
        .unwrap_err()
        .contains("git email"));
    assert!(validate_proton_email("nodomain")
        .unwrap_err()
        .contains("proton email"));
}
