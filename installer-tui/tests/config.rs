//! `InstallConfig` rendering + hostname/username validation tests.

use dots_installer::config::{validate_hostname, validate_username, InstallConfig};

#[test]
fn settings_nix_renders_all_answers() {
    let cfg = InstallConfig {
        disks: vec!["/dev/vda".into(), "/dev/vdb".into()],
        hostname: "myhost".into(),
        username: "alice".into(),
        swap_size_gib: 16,
        ..Default::default()
    };
    let out = cfg.settings_nix();
    assert!(out.contains(r#"username = "alice";"#), "{out}");
    assert!(out.contains(r#"hostname = "myhost";"#), "{out}");
    assert!(
        out.contains(r#"disks = [ "/dev/vda" "/dev/vdb" ];"#),
        "{out}"
    );
    assert!(out.contains(r#"swapSize = "16G";"#), "{out}");
    assert!(out.trim_start().starts_with('{') && out.trim_end().ends_with('}'));
}

#[test]
fn settings_nix_never_contains_passwords() {
    let cfg = InstallConfig {
        root_password: "rootsecret".into(),
        user_password: "usersecret".into(),
        ..Default::default()
    };
    let out = cfg.settings_nix();
    assert!(!out.contains("rootsecret"));
    assert!(!out.contains("usersecret"));
}

#[test]
fn hostname_accepts_rfc1123_labels() {
    assert!(validate_hostname("tokyonight").is_ok());
    assert!(validate_hostname("my-host2").is_ok());
}

#[test]
fn hostname_rejects_bad_labels() {
    assert!(validate_hostname("").is_err());
    assert!(validate_hostname("-leading").is_err());
    assert!(validate_hostname("trailing-").is_err());
    assert!(validate_hostname("Upper").is_err());
    assert!(validate_hostname("under_score").is_err());
    assert!(validate_hostname(&"a".repeat(64)).is_err());
}

#[test]
fn username_accepts_posix_names() {
    assert!(validate_username("matus").is_ok());
    assert!(validate_username("_svc").is_ok());
    assert!(validate_username("m-user_9").is_ok());
}

#[test]
fn username_rejects_bad_names() {
    assert!(validate_username("").is_err());
    assert!(validate_username("9lives").is_err());
    assert!(validate_username("Matus").is_err());
    assert!(validate_username("with space").is_err());
    assert!(validate_username(&"a".repeat(32)).is_err());
    assert!(validate_username("root").is_err(), "reserved name");
}
