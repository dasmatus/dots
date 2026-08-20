//! Tests for the `write` subcommand — the pkexec-elevated half of the rofi
//! frontend: it reads the full settings.nix from stdin, refuses anything
//! that does not parse, and atomically replaces the target file.

use std::io::Write;
use std::process::{Command, Stdio};

fn run_write(file: &std::path::Path, stdin: &str) -> std::process::ExitStatus {
    let mut child = Command::new(env!("CARGO_BIN_EXE_global-settings"))
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
