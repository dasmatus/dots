//! Integration tests for `broker::decide`/`resolve_prompt` and the audit
//! log they write.
//!
//! The prompt channels themselves (`qs ipc call sandboxprompt …`, a real
//! TTY read) aren't exercised here: this build environment has neither a
//! `qs` binary nor an interactive stdin, and simulating either would only
//! prove a mock answers the way the mock was told to. What is real
//! behaviour to test is the channel-selection precedence
//! (`resolve_prompt`) and the hard rule that a non-interactive app never
//! reaches a prompt at all (`decide`) — both exercised below without
//! touching an actual GUI or terminal.
use std::path::PathBuf;
use std::process;

use dots_sandbox::broker::{decide, resolve_prompt, AuditLog, Interactivity, Outcome};
use dots_sandbox::merge_stub::CapState;

fn tmp_audit(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "dots-sandbox-audit-broker-{name}-{}.jsonl",
        process::id()
    ))
}

#[test]
fn allow_is_always_allowed_regardless_of_interactivity() {
    for interactivity in [Interactivity::Interactive, Interactivity::NonInteractive] {
        let path = tmp_audit(&format!("allow-{interactivity:?}"));
        let audit = AuditLog::with_path(&path);
        let outcome = decide(&audit, "app", "network", CapState::Allow, interactivity);
        assert_eq!(outcome, Outcome::AllowedByPolicy);
        let _ = std::fs::remove_file(&path);
    }
}

#[test]
fn deny_is_always_denied_regardless_of_interactivity() {
    for interactivity in [Interactivity::Interactive, Interactivity::NonInteractive] {
        let path = tmp_audit(&format!("deny-{interactivity:?}"));
        let audit = AuditLog::with_path(&path);
        let outcome = decide(&audit, "app", "gpu", CapState::Deny, interactivity);
        assert_eq!(outcome, Outcome::DeniedByPolicy);
        let _ = std::fs::remove_file(&path);
    }
}

#[test]
fn ask_on_a_noninteractive_app_is_denied_without_ever_reaching_a_prompt() {
    // This is the correctness property the whole module exists for: a
    // wrapped CLI app (nix-lint under CI, over SSH, ...) must not hang
    // waiting for a prompt nobody can answer.
    let path = tmp_audit("ask-noninteractive");
    let audit = AuditLog::with_path(&path);
    let outcome = decide(
        &audit,
        "nix-lint",
        "camera",
        CapState::Ask,
        Interactivity::NonInteractive,
    );
    assert_eq!(outcome, Outcome::DeniedNonInteractive);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn decide_logs_the_capability_and_app_id_it_was_asked_about() {
    let path = tmp_audit("log-shape");
    let audit = AuditLog::with_path(&path);
    let outcome = decide(
        &audit,
        "firefox",
        "network",
        CapState::Allow,
        Interactivity::NonInteractive,
    );
    assert_eq!(outcome, Outcome::AllowedByPolicy);

    let content = std::fs::read_to_string(&path).unwrap();
    let line: serde_json::Value = serde_json::from_str(content.trim()).unwrap();
    assert_eq!(line["app_id"], "firefox");
    assert_eq!(line["capability"], "network");
    assert_eq!(line["kind"], "capability_request");
    assert_eq!(line["outcome"], "allowed_by_policy");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn resolve_prompt_prefers_an_explicit_gui_reply_over_the_tty() {
    assert_eq!(
        resolve_prompt(true, Some(true), true, Some(false)),
        Outcome::PromptApproved,
        "the GUI said yes; the (contradictory) TTY reply must not override it"
    );
    assert_eq!(
        resolve_prompt(true, Some(false), true, Some(true)),
        Outcome::PromptDenied
    );
}

#[test]
fn resolve_prompt_falls_back_to_tty_when_the_gui_channel_gives_no_answer() {
    // `None` here models both "no Wayland session" and "the qs call
    // failed or hung" — both should defer to the TTY.
    assert_eq!(
        resolve_prompt(true, None, true, Some(true)),
        Outcome::PromptApproved
    );
    assert_eq!(
        resolve_prompt(false, None, true, Some(true)),
        Outcome::PromptApproved
    );
}

#[test]
fn resolve_prompt_times_out_rather_than_denying_when_the_tty_never_answers() {
    assert_eq!(
        resolve_prompt(false, None, true, None),
        Outcome::PromptTimedOut
    );
}

#[test]
fn resolve_prompt_denies_when_neither_channel_exists() {
    assert_eq!(
        resolve_prompt(false, None, false, None),
        Outcome::DeniedNoPromptChannel
    );
}
