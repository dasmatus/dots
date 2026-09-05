//! Integration tests for `launch::run` against `merge_stub`'s stand-in
//! `spawn_argv`/`resolve_policy` (see that module's doc comment: it runs
//! `program`/`args` completely unwrapped, so these tests exercise real
//! child processes, real signals and real exit codes — the actual
//! plumbing this task owns — without needing the real sandboxing half to
//! exist yet.
use std::path::PathBuf;
use std::process;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use dots_sandbox::broker::{AuditLog, Interactivity};
use dots_sandbox::launch;

/// Signal handling is process-global, and `cargo test` runs every test in
/// this binary on its own thread within one process. The two
/// signal-forwarding tests below install real process-wide SIGTERM/SIGINT
/// handlers via `launch::run`, so they must not run concurrently with
/// each other; everything else here is signal-free and unaffected.
static SIGNAL_TESTS: Mutex<()> = Mutex::new(());

fn tmp_audit(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("dots-sandbox-audit-{name}-{}.jsonl", process::id()))
}

#[test]
fn propagates_the_childs_own_exit_code() {
    let path = tmp_audit("exit-code");
    let audit = AuditLog::with_path(&path);
    let outcome = launch::run(
        "t-exit",
        "/bin/sh",
        &["-c".to_owned(), "exit 7".to_owned()],
        Interactivity::NonInteractive,
        &audit,
    )
    .expect("run should succeed even though the child exits non-zero");
    assert_eq!(outcome.exit_code, 7);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn propagates_success() {
    let path = tmp_audit("success");
    let audit = AuditLog::with_path(&path);
    let outcome = launch::run("t-ok", "true", &[], Interactivity::NonInteractive, &audit)
        .expect("run should succeed");
    assert_eq!(outcome.exit_code, 0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn unknown_program_surfaces_a_spawn_error_rather_than_panicking() {
    let path = tmp_audit("bad-program");
    let audit = AuditLog::with_path(&path);
    let result = launch::run(
        "t-nope",
        "/no/such/binary-dots-sandbox-test",
        &[],
        Interactivity::NonInteractive,
        &audit,
    );
    assert!(
        result.is_err(),
        "spawning a nonexistent program should error, not panic"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn logs_every_capability_decision_for_the_dashboard() {
    let path = tmp_audit("capability-log");
    let audit = AuditLog::with_path(&path);
    launch::run(
        "dash-app",
        "true",
        &[],
        Interactivity::NonInteractive,
        &audit,
    )
    .expect("run should succeed");

    let content = std::fs::read_to_string(&path).expect("audit log should have been written");
    let lines: Vec<serde_json::Value> = content
        .lines()
        .map(|line| serde_json::from_str(line).expect("every audit line must be valid JSON"))
        .collect();

    // merge_stub::resolve_policy always returns network=allow,
    // camera=ask, gpu=deny; a non-interactive app must show all three
    // decided, with the `ask` one denied rather than ever prompted.
    let outcome_for = |capability: &str| -> String {
        lines
            .iter()
            .find(|l| l["capability"] == capability)
            .unwrap_or_else(|| panic!("no audit line for capability {capability:?}: {lines:#?}"))
            ["outcome"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(outcome_for("network"), "allowed_by_policy");
    assert_eq!(outcome_for("camera"), "denied_non_interactive");
    assert_eq!(outcome_for("gpu"), "denied_by_policy");

    for line in &lines {
        assert_eq!(line["app_id"], "dash-app");
        assert_eq!(line["kind"], "capability_request");
    }
    let _ = std::fs::remove_file(&path);
}

#[test]
fn forwards_sigterm_to_the_child_and_reports_its_conventional_exit_code() {
    let _guard = SIGNAL_TESTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let path = tmp_audit("sigterm");
    let audit = AuditLog::with_path(&path);

    // Sends SIGTERM to this very test process shortly after `run` starts
    // waiting on the child; `run` should relay it to `sleep`, which has
    // no handler of its own and dies from the signal rather than exiting
    // cleanly.
    let sender = thread::spawn(|| {
        thread::sleep(Duration::from_millis(300));
        unsafe {
            libc::kill(process::id() as libc::pid_t, libc::SIGTERM);
        }
    });

    let outcome = launch::run(
        "t-sigterm",
        "sleep",
        &["5".to_owned()],
        Interactivity::NonInteractive,
        &audit,
    )
    .expect("run itself should not error just because the child was signalled");
    sender.join().unwrap();

    assert_eq!(
        outcome.exit_code,
        128 + libc::SIGTERM,
        "a signal-terminated child should report the shell's conventional 128+signal code"
    );
    let _ = std::fs::remove_file(&path);
}

#[test]
fn forwards_sigint_to_the_child_too() {
    let _guard = SIGNAL_TESTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let path = tmp_audit("sigint");
    let audit = AuditLog::with_path(&path);

    let sender = thread::spawn(|| {
        thread::sleep(Duration::from_millis(300));
        unsafe {
            libc::kill(process::id() as libc::pid_t, libc::SIGINT);
        }
    });

    let outcome = launch::run(
        "t-sigint",
        "sleep",
        &["5".to_owned()],
        Interactivity::NonInteractive,
        &audit,
    )
    .expect("run itself should not error just because the child was signalled");
    sender.join().unwrap();

    assert_eq!(outcome.exit_code, 128 + libc::SIGINT);
    let _ = std::fs::remove_file(&path);
}
