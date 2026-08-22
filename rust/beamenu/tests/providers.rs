//! Provider parsing and formatting, none of which needs a compositor.

use std::path::{Path, PathBuf};

use beamenu::config::Config;
use beamenu::providers::apps::{clean_exec, parse_entry, scan};
use beamenu::providers::clipboard::{load, parse_log, preview, relative_age, Entry};
use beamenu::providers::files::{display_path, parse_output};
use beamenu::providers::quicklinks::{expand, percent_encode};
use beamenu::providers::scripts::{executables, parse_metadata};
use beamenu::providers::system::System;
use beamenu::providers::window::parse_clients;
use beamenu::providers::{Ctx, Provider};

// --- desktop entries ---

#[test]
fn parses_a_minimal_desktop_entry() {
    let parsed = parse_entry("[Desktop Entry]\nType=Application\nName=Files\nExec=nautilus\n")
        .expect("a well-formed entry parses");
    assert_eq!(parsed.name, "Files");
    assert_eq!(parsed.exec, "nautilus");
    assert!(!parsed.terminal);
}

#[test]
fn skips_entries_a_launcher_must_not_show() {
    let hidden = "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n";
    assert!(parse_entry(hidden).is_none());

    let removed = "[Desktop Entry]\nType=Application\nName=X\nExec=x\nHidden=true\n";
    assert!(parse_entry(removed).is_none());

    let link = "[Desktop Entry]\nType=Link\nName=X\nURL=http://x\n";
    assert!(parse_entry(link).is_none());

    let no_exec = "[Desktop Entry]\nType=Application\nName=X\n";
    assert!(parse_entry(no_exec).is_none());
}

#[test]
fn desktop_action_groups_do_not_override_the_main_entry() {
    let source = "[Desktop Entry]\nType=Application\nName=Claude\nExec=claude-desktop\n\
                  \n[Desktop Action NewChat]\nName=New chat\nExec=claude-desktop --new\n";
    let parsed = parse_entry(source).expect("parses");
    assert_eq!(parsed.name, "Claude");
    assert_eq!(parsed.exec, "claude-desktop");
}

#[test]
fn localised_keys_do_not_win_over_the_plain_one() {
    let source = "[Desktop Entry]\nType=Application\nName=Files\nName[de]=Dateien\nExec=nautilus\n";
    assert_eq!(parse_entry(source).unwrap().name, "Files");
}

#[test]
fn strips_exec_field_codes_but_keeps_literal_percent() {
    assert_eq!(clean_exec("firefox %u"), "firefox");
    assert_eq!(clean_exec("gimp %U %f"), "gimp");
    assert_eq!(clean_exec("thing --pct=100%%"), "thing --pct=100%");
    assert_eq!(clean_exec("app -x"), "app -x");
}

#[test]
fn later_directories_override_earlier_ones_by_entry_id() {
    let tmp = tempfile::tempdir().unwrap();
    let system = tmp.path().join("system/applications");
    let user = tmp.path().join("user/applications");
    std::fs::create_dir_all(&system).unwrap();
    std::fs::create_dir_all(&user).unwrap();

    std::fs::write(
        system.join("editor.desktop"),
        "[Desktop Entry]\nType=Application\nName=System Editor\nExec=sysedit\n",
    )
    .unwrap();
    std::fs::write(
        user.join("editor.desktop"),
        "[Desktop Entry]\nType=Application\nName=My Editor\nExec=myedit\n",
    )
    .unwrap();

    let dirs = vec![tmp.path().join("system"), tmp.path().join("user")];
    let found = scan(&dirs);
    assert_eq!(found["editor.desktop"].name, "My Editor");
}

#[test]
fn a_user_override_marked_nodisplay_removes_the_system_entry() {
    let tmp = tempfile::tempdir().unwrap();
    let system = tmp.path().join("system/applications");
    let user = tmp.path().join("user/applications");
    std::fs::create_dir_all(&system).unwrap();
    std::fs::create_dir_all(&user).unwrap();

    std::fs::write(
        system.join("thing.desktop"),
        "[Desktop Entry]\nType=Application\nName=Thing\nExec=thing\n",
    )
    .unwrap();
    std::fs::write(
        user.join("thing.desktop"),
        "[Desktop Entry]\nType=Application\nName=Thing\nExec=thing\nNoDisplay=true\n",
    )
    .unwrap();

    let dirs = vec![tmp.path().join("system"), tmp.path().join("user")];
    assert!(!scan(&dirs).contains_key("thing.desktop"));
}

// --- quicklinks ---

#[test]
fn expands_the_query_placeholder() {
    let url = expand("https://github.com/search?q={query}", "nix pkgs", false);
    assert_eq!(url, "https://github.com/search?q=nix%20pkgs");
}

#[test]
fn a_target_without_a_placeholder_is_left_alone() {
    let url = expand("https://example.com", "ignored", false);
    assert_eq!(url, "https://example.com");
}

#[test]
fn command_targets_are_shell_quoted_not_percent_encoded() {
    // The single quote is closed, escaped, and reopened, so the shell sees
    // one literal argument rather than a quote break.
    let command = expand("echo {query}", "it's here", true);
    assert_eq!(command, r"echo 'it'\''s here'");
}

#[test]
fn percent_encoding_leaves_the_unreserved_set_alone() {
    assert_eq!(percent_encode("aZ0-_.~"), "aZ0-_.~");
    assert_eq!(percent_encode("a b"), "a%20b");
    assert_eq!(percent_encode("&"), "%26");
}

// --- clipboard ---

#[test]
fn skips_unparseable_log_lines_rather_than_failing() {
    let log = "{\"at\":1,\"text\":\"one\"}\nnot json\n{\"at\":2,\"text\":\"two\"}\n";
    let entries = parse_log(log);
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].text, "one");
}

#[test]
fn history_is_newest_first_and_deduplicated() {
    let tmp = tempfile::tempdir().unwrap();
    let log = tmp.path().join("clipboard.jsonl");
    let body = "{\"at\":1,\"text\":\"a\"}\n{\"at\":2,\"text\":\"b\"}\n{\"at\":3,\"text\":\"a\"}\n";
    std::fs::write(&log, body).unwrap();

    let entries = load(&log);
    let texts: Vec<&str> = entries.iter().map(|e| e.text.as_str()).collect();
    // "a" was copied again most recently, so it leads and appears once.
    assert_eq!(texts, vec!["a", "b"]);
}

#[test]
fn append_then_load_round_trips() {
    let tmp = tempfile::tempdir().unwrap();
    let log = tmp.path().join("nested/clipboard.jsonl");
    beamenu::providers::clipboard::append(
        &log,
        &Entry {
            at: 7,
            text: "hello".into(),
        },
    )
    .unwrap();

    let entries = load(&log);
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].text, "hello");
}

#[test]
fn preview_collapses_whitespace_and_truncates() {
    assert_eq!(preview("a\n\nb   c"), "a b c");
    let long = "x".repeat(200);
    let shown = preview(&long);
    assert_eq!(shown.chars().count(), 80);
    assert!(shown.ends_with('\u{2026}'));
}

#[test]
fn relative_age_uses_coarse_units() {
    assert_eq!(relative_age(100, 130), "just now");
    assert_eq!(relative_age(0, 120), "2m ago");
    assert_eq!(relative_age(0, 7200), "2h ago");
    assert_eq!(relative_age(0, 172_800), "2d ago");
}

// --- script commands ---

#[test]
fn reads_the_metadata_header() {
    let source = "#!/usr/bin/env bash\n\
                  # @beamenu.title Restart Waybar\n\
                  # @beamenu.subtitle Kill and respawn\n\
                  echo hi\n";
    let meta = parse_metadata(source);
    assert_eq!(meta.title.as_deref(), Some("Restart Waybar"));
    assert_eq!(meta.subtitle.as_deref(), Some("Kill and respawn"));
}

#[test]
fn stops_reading_metadata_at_the_first_code_line() {
    // A string deep in the script must not be mistaken for metadata.
    let source = "#!/bin/sh\necho hello\n# @beamenu.title Sneaky\n";
    assert!(parse_metadata(source).title.is_none());
}

#[test]
fn finds_only_executable_files() {
    use std::os::unix::fs::PermissionsExt;

    let tmp = tempfile::tempdir().unwrap();
    let runnable = tmp.path().join("run.sh");
    let plain = tmp.path().join("notes.txt");
    std::fs::write(&runnable, "#!/bin/sh\n").unwrap();
    std::fs::write(&plain, "text").unwrap();
    std::fs::set_permissions(&runnable, std::fs::Permissions::from_mode(0o755)).unwrap();

    let found = executables(tmp.path());
    assert_eq!(found, vec![runnable]);
}

// --- system ---

#[test]
fn system_commands_carry_no_category_accessory() {
    // Providers no longer stamp a static type noun ("Command") into the
    // accessory slot; that space is reserved for functional hints such as
    // the action panel's "Enter"/"Action" (see tests/navigation.rs).
    let ctx = Ctx {
        config: Config::default(),
        config_dir: PathBuf::new(),
        state_dir: PathBuf::new(),
    };
    let items = System.query(&ctx, "");
    assert!(!items.is_empty(), "the command list is never empty");
    assert!(items.iter().all(|item| item.accessory.is_none()));
}

// --- windows ---

#[test]
fn parses_hyprctl_clients_and_drops_titleless_surfaces() {
    let json = r#"[
        {"address":"0x1","class":"kitty","title":"shell","workspace":{"name":"1"}},
        {"address":"0x2","class":"x","title":"  ","workspace":{"name":"2"}}
    ]"#;
    let clients = parse_clients(json);
    assert_eq!(clients.len(), 1);
    assert_eq!(clients[0].address, "0x1");
    assert_eq!(clients[0].workspace.name, "1");
}

#[test]
fn malformed_hyprctl_output_yields_no_windows() {
    assert!(parse_clients("not json").is_empty());
}

// --- files ---

#[test]
fn parses_fd_output_ignoring_blank_lines() {
    let paths = parse_output("a/b.txt\n\n c/d.rs \n");
    assert_eq!(
        paths,
        vec![PathBuf::from("a/b.txt"), PathBuf::from("c/d.rs")]
    );
}

#[test]
fn display_path_collapses_the_home_prefix() {
    let home = Path::new("/home/user");
    assert_eq!(
        display_path(Path::new("/home/user/docs/a.txt"), home),
        "~/docs/a.txt"
    );
    assert_eq!(display_path(Path::new("/etc/hosts"), home), "/etc/hosts");
}
