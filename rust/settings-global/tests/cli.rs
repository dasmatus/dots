//! Tests for the scripting-facing subcommands: `write` (the pkexec-elevated
//! half — reads the full settings.nix from stdin, refuses anything that does
//! not parse, atomically replaces the target file), `dump` (JSON array of
//! every field) and `set` (validate-then-save one field). `serve`'s
//! JSON-RPC conversation is covered separately in tests/serve.rs.

use global_settings::menu::ITEMS;
use std::io::Write;
use std::process::{Command, Stdio};

fn settings_bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_global-settings"))
}

fn temp_settings_file(name: &str, content: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("{name}-{}.nix", std::process::id()));
    std::fs::write(&path, content).unwrap();
    path
}

fn run_write(file: &std::path::Path, stdin: &str) -> std::process::ExitStatus {
    let mut child = settings_bin()
        .args(["write", "--file"])
        .arg(file)
        .stdin(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("binary must spawn");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait().unwrap()
}

#[test]
fn write_replaces_file_with_parsed_content() {
    let path = std::env::temp_dir().join(format!("cli-write-{}.nix", std::process::id()));
    std::fs::write(&path, "{\n  hostname = \"old\";\n}\n").unwrap();
    let status = run_write(&path, "{\n  hostname = \"new\";\n  aiClaude = true;\n}\n");
    assert!(status.success());
    let content = std::fs::read_to_string(&path).unwrap();
    assert!(content.contains("hostname = \"new\";"), "{content}");
    assert!(content.contains("aiClaude = true;"), "{content}");
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn write_rejects_garbage_and_leaves_file_untouched() {
    let path = std::env::temp_dir().join(format!("cli-garbage-{}.nix", std::process::id()));
    std::fs::write(&path, "{\n  hostname = \"keep\";\n}\n").unwrap();
    let status = run_write(&path, "this is not an attrset");
    assert!(!status.success());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "{\n  hostname = \"keep\";\n}\n"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn dump_prints_the_documented_json_shape() {
    let path = temp_settings_file(
        "cli-dump",
        "{\n  hostname = \"box\";\n  gitName = \"Ada\";\n  gitEmail = \"a@b.com\";\n  aiClaude = true;\n  aiCodex = false;\n  aiOllama = true;\n}\n",
    );
    let output = settings_bin()
        .args(["dump", "--file"])
        .arg(&path)
        .output()
        .expect("binary must spawn");
    assert!(output.status.success(), "{:?}", output.status);
    let parsed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("dump must print JSON");
    let items = parsed.as_array().expect("dump prints a JSON array");
    // Against ITEMS.len(), not a literal: a hardcoded 6 here made adding one
    // menu row fail a test that has nothing to say about which rows exist.
    assert_eq!(items.len(), ITEMS.len());
    let hostname = items.iter().find(|i| i["key"] == "hostname").unwrap();
    assert_eq!(hostname["type"], "text");
    assert_eq!(hostname["value"], "box");
    assert_eq!(hostname["prompt"], "Hostname");
    let ollama = items.iter().find(|i| i["key"] == "aiOllama").unwrap();
    assert_eq!(ollama["type"], "checkbox");
    assert_eq!(ollama["value"], true);
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_saves_a_valid_text_field() {
    let path = temp_settings_file("cli-set-text", "{\n  hostname = \"old\";\n}\n");
    let status = settings_bin()
        .args(["set", "hostname", "newhost", "--file"])
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success());
    let content = std::fs::read_to_string(&path).unwrap();
    assert!(content.contains("hostname = \"newhost\";"), "{content}");
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_saves_a_valid_checkbox_field() {
    let path = temp_settings_file("cli-set-bool", "{\n  aiCodex = false;\n}\n");
    let status = settings_bin()
        .args(["set", "aiCodex", "true", "--file"])
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("aiCodex = true;"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_rejects_invalid_value_and_leaves_file_untouched() {
    let path = temp_settings_file("cli-set-invalid", "{\n  hostname = \"keep\";\n}\n");
    let output = settings_bin()
        .args(["set", "hostname", "UpperCase", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(!output.stderr.is_empty());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "{\n  hostname = \"keep\";\n}\n"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_rejects_unknown_key() {
    let path = temp_settings_file("cli-set-unknown", "{\n  hostname = \"keep\";\n}\n");
    let output = settings_bin()
        .args(["set", "notAKey", "x", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "{\n  hostname = \"keep\";\n}\n"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_rejects_non_boolean_for_checkbox_key() {
    let path = temp_settings_file("cli-set-badbool", "{\n  aiCodex = false;\n}\n");
    let output = settings_bin()
        .args(["set", "aiCodex", "yes", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("aiCodex = false;"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_saves_a_valid_number_field() {
    let path = temp_settings_file("cli-set-int", "{\n  wmGapsIn = 5;\n}\n");
    let status = settings_bin()
        .args(["set", "wmGapsIn", "20", "--file"])
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("wmGapsIn = 20;"));
    std::fs::remove_file(&path).unwrap();
}

/// `Settings.qml`'s writer surfaces a non-zero exit as "a field was
/// rejected" — a number field given non-numeric text must fail loudly
/// rather than write a garbage value.
#[test]
fn set_rejects_non_integer_for_number_key_with_a_clear_message() {
    let path = temp_settings_file("cli-set-badint", "{\n  wmGapsIn = 5;\n}\n");
    let output = settings_bin()
        .args(["set", "wmGapsIn", "abc", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("wmGapsIn"), "{stderr}");
    assert!(
        std::fs::read_to_string(&path)
            .unwrap()
            .contains("wmGapsIn = 5;"),
        "value must be left untouched on a rejected set"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_rejects_out_of_range_number() {
    let path = temp_settings_file("cli-set-int-range", "{\n  wmGapsIn = 5;\n}\n");
    let output = settings_bin()
        .args(["set", "wmGapsIn", "999", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("wmGapsIn = 5;"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_saves_a_valid_select_field() {
    let path = temp_settings_file("cli-set-select", "{\n  wmLayout = \"dwindle\";\n}\n");
    let status = settings_bin()
        .args(["set", "wmLayout", "master", "--file"])
        .arg(&path)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("wmLayout = \"master\";"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn set_rejects_a_select_value_outside_its_options() {
    let path = temp_settings_file("cli-set-select-bad", "{\n  wmLayout = \"dwindle\";\n}\n");
    let output = settings_bin()
        .args(["set", "wmLayout", "spiral", "--file"])
        .arg(&path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("wmLayout = \"dwindle\";"));
    std::fs::remove_file(&path).unwrap();
}
