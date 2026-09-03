//! `InstallConfig` rendering + hostname/username/git validation tests.

use dots_installer::config::{
    validate_git_email, validate_git_name, validate_hostname, validate_username, InstallConfig,
};

#[test]
fn settings_nix_renders_all_answers() {
    let cfg = InstallConfig {
        disks: vec!["/dev/vda".into(), "/dev/vdb".into()],
        hostname: "myhost".into(),
        username: "alice".into(),
        git_name: "Alice Q".into(),
        git_email: "alice@example.org".into(),
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
    assert!(out.contains(r#"gitName = "Alice Q";"#), "{out}");
    assert!(out.contains(r#"gitEmail = "alice@example.org";"#), "{out}");
    assert!(out.trim_start().starts_with('{') && out.trim_end().ends_with('}'));
}

#[test]
fn settings_nix_never_contains_passwords() {
    let cfg = InstallConfig {
        user_password: "usersecret".into(),
        ..Default::default()
    };
    let out = cfg.settings_nix();
    assert!(!out.contains("usersecret"));
}

#[test]
fn settings_nix_escapes_quotes_and_backslashes_in_git_identity() {
    let cfg = InstallConfig {
        git_name: r#"Alice "bo" \o/"#.into(),
        git_email: r#"a\b"e"@example.org"#.into(),
        ..Default::default()
    };
    let out = cfg.settings_nix();
    // Backslash and double-quote must be backslash-escaped so the rendered
    // Nix string literal stays valid.
    assert!(out.contains(r#"gitName = "Alice \"bo\" \\o/";"#), "{out}");
    assert!(
        out.contains(r#"gitEmail = "a\\b\"e\"@example.org";"#),
        "{out}"
    );
}

#[test]
fn settings_nix_escapes_dollar_interpolation_in_git_identity() {
    let cfg = InstallConfig {
        git_name: "${builtins.readFile /etc/shadow}".into(),
        ..Default::default()
    };
    let out = cfg.settings_nix();
    // `${...}` is Nix interpolation; an unescaped value would be evaluated at
    // rebuild time, so the `$` must be backslash-escaped to a literal.
    assert!(
        out.contains(r#"gitName = "\${builtins.readFile /etc/shadow}";"#),
        "{out}"
    );
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
    assert!(validate_username("Ada").is_err());
    assert!(validate_username("with space").is_err());
    assert!(validate_username(&"a".repeat(32)).is_err());
    assert!(validate_username("root").is_err(), "reserved name");
}

#[test]
fn git_name_accepts_real_names() {
    assert!(validate_git_name("Ada Lovelace").is_ok());
    assert!(validate_git_name("O'Brien").is_ok());
    assert!(validate_git_name("田中").is_ok());
    assert!(validate_git_name(&"a".repeat(128)).is_ok());
}

#[test]
fn git_name_rejects_empty_newlines_and_too_long() {
    assert!(validate_git_name("").is_err());
    assert!(validate_git_name("   ").is_err());
    assert!(validate_git_name("with\nnewline").is_err());
    assert!(validate_git_name("carriage\rreturn").is_err());
    assert!(validate_git_name(&"a".repeat(129)).is_err());
}

#[test]
fn git_email_accepts_well_formed() {
    assert!(validate_git_email("alice@example.org").is_ok());
    assert!(validate_git_email("a.b+c@sub.example.org").is_ok());
    assert!(validate_git_email("user@my.co").is_ok());
}

#[test]
fn git_email_rejects_malformed() {
    assert!(validate_git_email("").is_err());
    assert!(validate_git_email("no-at-sign.example.org").is_err());
    assert!(validate_git_email("local-only@").is_err());
    assert!(validate_git_email("@example.org").is_err());
    assert!(validate_git_email("two@@at.example.org").is_err());
    assert!(validate_git_email("no-dot@example").is_err());
    assert!(validate_git_email("space in @example.org").is_err());
}
