//! Plugin manifest parsing, `{query}` substitution and mode-to-action
//! mapping, none of which needs a compositor.

use std::path::{Path, PathBuf};

use beamenu::config::Config;
use beamenu::index::AppCache;
use beamenu::item::Action;
use beamenu::providers::plugins::{expand, load_all, Manifest, Mode, Ui};
use beamenu::providers::{collect, Ctx, Provider, Trigger};

fn ctx(dir: &Path) -> Ctx {
    Ctx {
        config: Config::default(),
        config_dir: dir.to_path_buf(),
        state_dir: dir.to_path_buf(),
        apps: AppCache::default(),
    }
}

fn write_manifest(dir: &Path, filename: &str, json: &str) -> PathBuf {
    let path = dir.join(filename);
    std::fs::write(&path, json).unwrap();
    path
}

// --- manifest parsing ---

#[test]
fn parses_a_manifest_with_every_optional_field_present() {
    let json = r#"{
        "name": "claude", "title": "Claude Code", "icon": "/opt/claude.svg",
        "keyword": "cl",
        "commands": [
            { "id": "ask", "title": "Ask Claude", "description": "Prompt Claude Code",
              "mode": "view", "ui": "log", "exec": ["bash", "-lc", "claude {query}"] }
        ]
    }"#;
    let manifest: Manifest = serde_json::from_str(json).expect("well-formed manifest parses");

    assert_eq!(manifest.name, "claude");
    assert_eq!(manifest.title, "Claude Code");
    assert_eq!(manifest.icon.as_deref(), Some("/opt/claude.svg"));
    assert_eq!(manifest.keyword.as_deref(), Some("cl"));
    assert_eq!(manifest.commands.len(), 1);
    assert_eq!(
        manifest.commands[0].description.as_deref(),
        Some("Prompt Claude Code")
    );
    assert_eq!(manifest.commands[0].mode, Mode::View);
    assert_eq!(manifest.commands[0].ui, Ui::Log);
}

#[test]
fn optional_fields_default_when_absent() {
    let json = r#"{
        "name": "quick", "title": "Quick Actions",
        "commands": [
            { "id": "run", "title": "Run", "mode": "exec", "exec": ["true"] }
        ]
    }"#;
    let manifest: Manifest = serde_json::from_str(json).expect("optional fields may be omitted");

    assert!(manifest.icon.is_none());
    assert!(manifest.keyword.is_none());
    assert!(manifest.commands[0].description.is_none());
    // `ui` defaults to log, the auto-scrolling plain-text renderer, when a
    // command does not name one.
    assert_eq!(manifest.commands[0].ui, Ui::Log);
    assert!(
        manifest.commands[0].actions.is_empty(),
        "a manifest written before actions existed must still parse"
    );
}

#[test]
fn a_manifest_with_broken_json_is_skipped_not_fatal() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "good.json",
        r#"{"name":"good","title":"Good","commands":[]}"#,
    );
    write_manifest(tmp.path(), "bad.json", "{ not json");

    let loaded = load_all(tmp.path());
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].manifest.name, "good");
}

#[test]
fn a_missing_plugins_directory_yields_no_providers() {
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("does-not-exist");
    assert!(load_all(&missing).is_empty());
}

#[test]
fn non_json_files_in_the_plugins_directory_are_ignored() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "real.json",
        r#"{"name":"real","title":"Real","commands":[]}"#,
    );
    std::fs::write(tmp.path().join("README.md"), "not a manifest").unwrap();

    let loaded = load_all(tmp.path());
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].manifest.name, "real");
}

// --- {query} substitution ---

#[test]
fn query_placeholder_is_replaced_in_every_argv_element() {
    let argv = vec![
        "bash".to_string(),
        "-lc".to_string(),
        "echo {query} again {query}".to_string(),
    ];
    let expanded = expand(&argv, "hi there");
    assert_eq!(
        expanded,
        vec!["bash", "-lc", "echo hi there again hi there"]
    );
}

#[test]
fn a_command_without_the_placeholder_is_left_alone() {
    let argv = vec!["true".to_string()];
    assert_eq!(expand(&argv, "ignored"), vec!["true".to_string()]);
}

// --- keyword narrowing ---

#[test]
fn a_keyword_narrows_the_root_list_to_one_plugins_commands() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "claude.json",
        r#"{"name":"claude","title":"Claude Code","keyword":"cl",
            "commands":[{"id":"ask","title":"Ask Claude","mode":"exec","exec":["true"]}]}"#,
    );
    write_manifest(
        tmp.path(),
        "notes.json",
        r#"{"name":"notes","title":"Notes",
            "commands":[{"id":"new","title":"New Note","mode":"exec","exec":["true"]}]}"#,
    );

    let providers: Vec<Box<dyn Provider>> = load_all(tmp.path())
        .into_iter()
        .map(|provider| Box::new(provider) as Box<dyn Provider>)
        .collect();

    let context = ctx(tmp.path());
    let (items, rank_query) = collect(&providers, &context, "cl ask");

    // A keyworded provider answers alone, the same as the calculator or the
    // window switcher: the notes plugin's commands must not appear.
    assert_eq!(rank_query, "");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Ask Claude");
    assert_eq!(items[0].section.as_deref(), Some("Claude Code"));
}

#[test]
fn a_plugin_without_a_keyword_is_ambient() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "notes.json",
        r#"{"name":"notes","title":"Notes","commands":[]}"#,
    );

    let providers = load_all(tmp.path());
    assert_eq!(providers[0].trigger(), Trigger::Ambient);
}

#[test]
fn a_keyword_without_a_trailing_space_gets_one_appended() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "claude.json",
        r#"{"name":"claude","title":"Claude Code","keyword":"cl","commands":[]}"#,
    );

    let providers = load_all(tmp.path());
    assert_eq!(providers[0].trigger(), Trigger::Prefix("cl ".to_string()));
}

#[test]
fn a_keyword_already_ending_in_whitespace_is_not_double_spaced() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "claude.json",
        r#"{"name":"claude","title":"Claude Code","keyword":"cl ","commands":[]}"#,
    );

    let providers = load_all(tmp.path());
    assert_eq!(providers[0].trigger(), Trigger::Prefix("cl ".to_string()));
}

#[test]
fn a_keyword_does_not_match_a_query_that_merely_starts_with_its_letters() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "claude.json",
        r#"{"name":"claude","title":"Claude Code","keyword":"cl",
            "commands":[{"id":"ask","title":"Ask Claude","mode":"exec","exec":["true"]}]}"#,
    );

    let providers: Vec<Box<dyn Provider>> = load_all(tmp.path())
        .into_iter()
        .map(|provider| Box::new(provider) as Box<dyn Provider>)
        .collect();

    let context = ctx(tmp.path());
    // "clone repo" starts with "cl" but not at a word boundary, so the
    // unmatched keyword must fall through rather than swallow it.
    let (items, rank_query) = collect(&providers, &context, "clone repo");

    assert!(items.is_empty());
    assert_eq!(rank_query, "clone repo");
}

#[test]
fn a_keyword_triggers_at_a_word_boundary_with_the_remainder_as_query() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "claude.json",
        r#"{"name":"claude","title":"Claude Code","keyword":"cl",
            "commands":[{"id":"ask","title":"Ask Claude","mode":"exec","exec":["echo","{query}"]}]}"#,
    );

    let providers: Vec<Box<dyn Provider>> = load_all(tmp.path())
        .into_iter()
        .map(|provider| Box::new(provider) as Box<dyn Provider>)
        .collect();

    let context = ctx(tmp.path());
    let (items, rank_query) = collect(&providers, &context, "cl foo");

    assert_eq!(rank_query, "");
    assert_eq!(items.len(), 1);
    match &items[0].action {
        Action::Launch { exec, .. } => assert_eq!(exec, "'echo' 'foo'"),
        other => panic!("expected Action::Launch, got {other:?}"),
    }
}

// --- mode -> Action mapping ---

#[test]
fn exec_mode_maps_to_a_detached_launch() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "run.json",
        r#"{"name":"run","title":"Run",
            "commands":[{"id":"go","title":"Go","mode":"exec","exec":["echo","{query}"]}]}"#,
    );

    let providers = load_all(tmp.path());
    let items = providers[0].query(&ctx(tmp.path()), "hi");

    match &items[0].action {
        Action::Launch { exec, terminal } => {
            assert!(!terminal);
            assert_eq!(exec, "'echo' 'hi'");
        }
        other => panic!("expected Action::Launch, got {other:?}"),
    }
}

#[test]
fn terminal_mode_maps_to_a_launch_wrapped_in_the_terminal() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "run.json",
        r#"{"name":"run","title":"Run",
            "commands":[{"id":"go","title":"Go","mode":"terminal","exec":["top"]}]}"#,
    );

    let providers = load_all(tmp.path());
    let items = providers[0].query(&ctx(tmp.path()), "");

    match &items[0].action {
        Action::Launch { exec, terminal } => {
            assert!(terminal);
            assert_eq!(exec, "'top'");
        }
        other => panic!("expected Action::Launch, got {other:?}"),
    }
}

#[test]
fn copy_mode_copies_the_substituted_exec_joined_as_a_shell_command() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "clip.json",
        r#"{"name":"clip","title":"Clip",
            "commands":[{"id":"phrase","title":"Phrase","mode":"copy","exec":["echo","it's {query}"]}]}"#,
    );

    let providers = load_all(tmp.path());
    let items = providers[0].query(&ctx(tmp.path()), "here");

    match &items[0].action {
        // Copy carries the joined command text itself, not anything a spawned
        // process would print: this mode never runs `exec`.
        Action::Copy(text) => assert_eq!(text, r"'echo' 'it'\''s here'"),
        other => panic!("expected Action::Copy, got {other:?}"),
    }
}

#[test]
fn view_mode_carries_the_manifest_path_command_id_and_query_for_the_canvas_argv() {
    let tmp = tempfile::tempdir().unwrap();
    let manifest_path = write_manifest(
        tmp.path(),
        "sidecar.json",
        r#"{"name":"sidecar","title":"Sidecar",
            "commands":[{"id":"open","title":"Open","mode":"view","exec":["true"]}]}"#,
    );

    let providers = load_all(tmp.path());
    let items = providers[0].query(&ctx(tmp.path()), "hi there");

    match &items[0].action {
        Action::View {
            manifest,
            command,
            query,
        } => {
            assert_eq!(manifest, &manifest_path);
            assert_eq!(command, "open");
            assert_eq!(query, "hi there");
        }
        other => panic!("expected Action::View, got {other:?}"),
    }
}

// --- one provider per manifest ---

#[test]
fn each_manifest_becomes_its_own_provider_with_its_own_section_and_id() {
    let tmp = tempfile::tempdir().unwrap();
    write_manifest(
        tmp.path(),
        "a.json",
        r#"{"name":"a","title":"Section A",
            "commands":[{"id":"x","title":"X","mode":"exec","exec":["true"]}]}"#,
    );
    write_manifest(
        tmp.path(),
        "b.json",
        r#"{"name":"b","title":"Section B",
            "commands":[{"id":"y","title":"Y","mode":"exec","exec":["true"]}]}"#,
    );

    let providers = load_all(tmp.path());
    assert_eq!(providers.len(), 2);

    let ids: Vec<&str> = providers.iter().map(Provider::id).collect();
    let sections: Vec<&str> = providers.iter().map(Provider::section).collect();
    assert_eq!(ids, vec!["a", "b"]);
    assert_eq!(sections, vec!["Section A", "Section B"]);
}

// --- command actions ---

#[test]
fn actions_become_alt_actions_with_the_same_query_expansion() {
    let dir = tempfile::tempdir().unwrap();
    write_manifest(
        dir.path(),
        "wp.json",
        r#"{
            "name": "wp", "title": "Wallpaper", "keyword": "wp",
            "commands": [{
                "id": "pick", "title": "Pick", "mode": "terminal",
                "exec": ["wallpaper-tui"],
                "actions": [
                    { "id": "restore", "title": "Restore", "mode": "exec",
                      "exec": ["wallpaper-tui", "--restore", "{query}"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "monet");

    assert_eq!(
        items[0].alt_actions,
        vec![(
            "Restore".to_string(),
            Action::Launch {
                exec: "'wallpaper-tui' '--restore' 'monet'".to_string(),
                terminal: false,
            },
        )]
    );
}

#[test]
fn view_mode_actions_carry_the_action_id_not_the_command_id() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_manifest(
        dir.path(),
        "docs.json",
        r#"{
            "name": "docs", "title": "Docs",
            "commands": [{
                "id": "open", "title": "Open", "mode": "exec", "exec": ["true"],
                "actions": [
                    { "id": "help", "title": "Help", "mode": "view",
                      "ui": "log", "exec": ["man", "beamenu"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "x");

    assert_eq!(
        items[0].alt_actions[0].1,
        Action::View {
            manifest: path,
            command: "help".to_string(),
            query: "x".to_string()
        }
    );
}

#[test]
fn every_mode_maps_the_same_way_for_an_action_as_for_a_command() {
    let dir = tempfile::tempdir().unwrap();
    write_manifest(
        dir.path(),
        "modes.json",
        r#"{
            "name": "modes", "title": "Modes",
            "commands": [{
                "id": "root", "title": "Root", "mode": "exec", "exec": ["true"],
                "actions": [
                    { "id": "term", "title": "Term", "mode": "terminal",
                      "exec": ["htop", "{query}"] },
                    { "id": "clip", "title": "Clip", "mode": "copy",
                      "exec": ["echo", "{query}"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "load");

    assert_eq!(
        items[0].alt_actions[0].1,
        Action::Launch {
            exec: "'htop' 'load'".to_string(),
            terminal: true,
        },
        "a terminal action wraps in the configured terminal, like a terminal command"
    );
    assert_eq!(
        items[0].alt_actions[1].1,
        Action::Copy("'echo' 'load'".to_string()),
        "a copy action copies the command text rather than running it"
    );
}

#[test]
fn a_command_without_actions_gets_no_alternates() {
    let dir = tempfile::tempdir().unwrap();
    write_manifest(
        dir.path(),
        "plain.json",
        r#"{
            "name": "plain", "title": "Plain",
            "commands": [ { "id": "run", "title": "Run", "mode": "exec", "exec": ["true"] } ]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "");

    assert!(
        items[0].alt_actions.is_empty(),
        "a manifest that declares no actions must behave exactly as it did before actions existed"
    );
}

#[test]
fn a_hostile_query_stays_one_shell_word_inside_an_action() {
    let dir = tempfile::tempdir().unwrap();
    write_manifest(
        dir.path(),
        "hostile.json",
        r#"{
            "name": "hostile", "title": "Hostile", "keyword": "h",
            "commands": [{
                "id": "root", "title": "Root", "mode": "exec", "exec": ["true"],
                "actions": [
                    { "id": "sub", "title": "Sub", "mode": "exec",
                      "exec": ["echo", "{query}"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "it's; rm -rf $(pwd) `id`");

    assert_eq!(
        items[0].alt_actions[0].1,
        Action::Launch {
            exec: r"'echo' 'it'\''s; rm -rf $(pwd) `id`'".to_string(),
            terminal: false,
        },
        "the query is one quoted word, so no metacharacter in it can reach the shell"
    );
}
