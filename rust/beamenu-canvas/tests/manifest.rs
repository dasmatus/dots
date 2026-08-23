//! Manifest parsing, command lookup and `{query}` substitution.

use beamenu_canvas::manifest::{substitute_query, Manifest, Mode, Ui};

const SAMPLE: &str = r#"{
    "name": "demo",
    "title": "Demo Plugin",
    "icon": "/opt/demo/icon.svg",
    "keyword": "demo",
    "commands": [
        {
            "id": "search",
            "title": "Search demo",
            "description": "Search the demo index",
            "mode": "view",
            "ui": "rpc",
            "exec": ["demo-worker", "--query", "{query}"]
        },
        {
            "id": "log-tail",
            "title": "Tail the log",
            "mode": "view",
            "exec": ["demo-worker", "tail"]
        }
    ]
}"#;

#[test]
fn parses_full_manifest() {
    let manifest = Manifest::parse(SAMPLE).expect("valid manifest");
    assert_eq!(manifest.name, "demo");
    assert_eq!(manifest.title, "Demo Plugin");
    assert_eq!(manifest.icon.as_deref(), Some("/opt/demo/icon.svg"));
    assert_eq!(manifest.keyword.as_deref(), Some("demo"));
    assert_eq!(manifest.commands.len(), 2);
}

#[test]
fn command_default_ui_is_log() {
    let manifest = Manifest::parse(SAMPLE).expect("valid manifest");
    let command = manifest.find_command("log-tail").expect("command exists");
    assert_eq!(command.ui, Ui::Log);
    assert_eq!(command.mode, Mode::View);
}

#[test]
fn command_explicit_ui_is_honoured() {
    let manifest = Manifest::parse(SAMPLE).expect("valid manifest");
    let command = manifest.find_command("search").expect("command exists");
    assert_eq!(command.ui, Ui::Rpc);
}

#[test]
fn find_command_returns_none_for_missing_id() {
    let manifest = Manifest::parse(SAMPLE).expect("valid manifest");
    assert!(manifest.find_command("nope").is_none());
}

#[test]
fn command_helper_errors_on_missing_id() {
    let manifest = Manifest::parse(SAMPLE).expect("valid manifest");
    let err = manifest.command("nope").expect_err("no such command");
    assert!(err.to_string().contains("nope"));
}

#[test]
fn parse_rejects_malformed_json() {
    let err = Manifest::parse("{ not json").expect_err("malformed json rejected");
    assert!(err.to_string().contains("invalid plugin manifest"));
}

#[test]
fn parse_rejects_missing_required_field() {
    // No "commands" array at all.
    let raw = r#"{"name": "demo", "title": "Demo"}"#;
    assert!(Manifest::parse(raw).is_err());
}

#[test]
fn parse_rejects_unknown_mode() {
    let raw = r#"{
        "name": "demo", "title": "Demo",
        "commands": [{"id":"x","title":"X","mode":"teleport","exec":["x"]}]
    }"#;
    assert!(Manifest::parse(raw).is_err());
}

#[test]
fn substitutes_query_into_every_matching_element() {
    let argv = vec![
        "demo-worker".to_string(),
        "--query".to_string(),
        "{query}".to_string(),
        "prefix-{query}-suffix".to_string(),
        "no-placeholder".to_string(),
    ];
    let out = substitute_query(&argv, Some("hello world"));
    assert_eq!(
        out,
        vec![
            "demo-worker",
            "--query",
            "hello world",
            "prefix-hello world-suffix",
            "no-placeholder",
        ]
    );
}

#[test]
fn substitutes_every_occurrence_within_one_element() {
    let argv = vec!["{query}/{query}".to_string()];
    let out = substitute_query(&argv, Some("x"));
    assert_eq!(out, vec!["x/x"]);
}

#[test]
fn missing_query_substitutes_empty_string() {
    let argv = vec!["prefix-{query}".to_string()];
    let out = substitute_query(&argv, None);
    assert_eq!(out, vec!["prefix-"]);
}

#[test]
fn substitute_query_is_noop_without_placeholder() {
    let argv = vec!["plain".to_string(), "args".to_string()];
    let out = substitute_query(&argv, Some("ignored"));
    assert_eq!(out, argv);
}
