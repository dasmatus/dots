//! Integration tests for `launch::run` against the real policy pipeline:
//! a fixture `defaults.json` on disk, read through
//! `$DOTS_SANDBOX_DEFAULTS`, and resolved via the real
//! `policy::resolve_app`/`argv::spawn_argv`.
//!
//! Every app this file resolves as `unconfined` (see [`write_fixture`])
//! runs its program directly, with no `systemd-nspawn`/`systemd-vmspawn`
//! wrapper — exactly the real behaviour for an app that opts out of
//! sandboxing, and exactly what these tests need to exercise real child
//! processes, real signals and real exit codes without depending on a
//! container rootfs or a VM kernel image that this environment does not
//! have (that Nix-side wiring is a later task; see `launch::build_ctx`'s
//! own doc comment). `dash_app` is the one test that resolves as
//! `Sandboxed` instead, to prove capability decisions get logged; it does
//! not assert on the resulting exit code, since `systemd-nspawn` itself
//! is expected to fail fast here — no `--directory=` target exists on
//! this machine, and unprivileged `--private-users=managed` needs
//! `systemd-nsresourced`, which is not enabled either (see
//! `tests/live_grant.rs`) — only that `launch::run` itself does not
//! error out before getting that far.
//!
//! `$HOME`/`$DOTS_SANDBOX_DEFAULTS`/`$XDG_RUNTIME_DIR` are process-global,
//! so every test here runs under one shared mutex rather than risking a
//! data race between threads `cargo test` runs concurrently within this
//! binary.
use std::path::PathBuf;
use std::process;
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use dots_sandbox::broker::{AuditLog, Interactivity};
use dots_sandbox::launch;

/// Every test in this file either mutates process-global environment
/// (`$HOME`, `$DOTS_SANDBOX_DEFAULTS`, `$XDG_RUNTIME_DIR`) or installs a
/// real process-wide signal handler via `launch::run`; either way, two
/// tests running at once on their own threads (`cargo test`'s default)
/// would race. One mutex serializes the whole file.
static TEST_SERIAL: Mutex<()> = Mutex::new(());

fn tmp_audit(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("dots-sandbox-audit-{name}-{}.jsonl", process::id()))
}

/// A `defaults.json` fixture covering every app id this file resolves:
/// four `unconfined` apps (one per behavioural test below, run directly
/// with no sandbox wrapper) and one `dash-app` sandboxed under the
/// `container` tier with one capability in each of the three resolvable
/// states, to exercise `broker::decide`'s full range.
fn write_fixture() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "dots-sandbox-launch-test-defaults-{}.json",
        process::id()
    ));
    let contents = r#"{
        "version": 1,
        "apps": {
            "t-exit": { "unconfined": true, "reason": "test fixture: run the child directly, no sandbox wrapper" },
            "t-ok": { "unconfined": true, "reason": "test fixture: run the child directly, no sandbox wrapper" },
            "t-nope": { "unconfined": true, "reason": "test fixture: run the child directly, no sandbox wrapper" },
            "t-sigterm": { "unconfined": true, "reason": "test fixture: run the child directly, no sandbox wrapper" },
            "t-sigint": { "unconfined": true, "reason": "test fixture: run the child directly, no sandbox wrapper" },
            "dash-app": {
                "tier": "container",
                "caps": { "net": "allow", "kvm": "ask", "postgres": "deny" }
            }
        },
        "denyPaths": []
    }"#;
    std::fs::write(&path, contents).expect("failed to write the test fixture defaults.json");
    path
}

/// Points `$HOME`/`$DOTS_SANDBOX_DEFAULTS`/`$XDG_RUNTIME_DIR` at the
/// fixture above and an isolated, non-existent home directory — so
/// `resolve_policy`'s optional overrides layer is reliably absent rather
/// than depending on whatever `~/.config/dots-sandbox/overrides.json`
/// happens to hold on the machine running this test.
fn set_fixture_env() {
    let home =
        std::env::temp_dir().join(format!("dots-sandbox-launch-test-home-{}", process::id()));
    let defaults = write_fixture();
    // Safety (in the sense of avoiding a data race, not memory unsafety):
    // every caller of this function holds `TEST_SERIAL` for the duration
    // of the test, so no other thread in this binary reads or writes the
    // environment concurrently with these calls.
    std::env::set_var("HOME", &home);
    std::env::set_var("DOTS_SANDBOX_DEFAULTS", &defaults);
    std::env::set_var("XDG_RUNTIME_DIR", std::env::temp_dir());
}

#[test]
fn propagates_the_childs_own_exit_code() {
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
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
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
    let path = tmp_audit("success");
    let audit = AuditLog::with_path(&path);
    let outcome = launch::run("t-ok", "true", &[], Interactivity::NonInteractive, &audit)
        .expect("run should succeed");
    assert_eq!(outcome.exit_code, 0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn unknown_program_surfaces_a_spawn_error_rather_than_panicking() {
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
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
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
    // This host has no `systemd-nsresourced`, so `launch::run` would normally
    // degrade to unconfined and never reach the capability decisions this test
    // is about. Requiring the runtime forces the sandboxed path: the child
    // still cannot actually start (see the comment below), which is fine —
    // the decisions are logged before the spawn is attempted.
    std::env::set_var("DOTS_SANDBOX_REQUIRE_RUNTIME", "1");
    let path = tmp_audit("capability-log");
    let audit = AuditLog::with_path(&path);
    // `dash-app` resolves as `Sandboxed`, so this does reach the real
    // `spawn_argv` and attempt a real `systemd-nspawn` launch; that is
    // expected to fail fast (no rootfs, no `systemd-nsresourced` — see
    // this file's module doc comment), but `launch::run` itself still
    // succeeds: a sandboxed child exiting badly is not a `launch::run`
    // error, only a low exit code this test does not assert on.
    launch::run(
        "dash-app",
        "true",
        &[],
        Interactivity::NonInteractive,
        &audit,
    )
    .expect("run should succeed even though the sandboxed child cannot actually start here");

    let content = std::fs::read_to_string(&path).expect("audit log should have been written");
    let lines: Vec<serde_json::Value> = content
        .lines()
        .map(|line| serde_json::from_str(line).expect("every audit line must be valid JSON"))
        .collect();

    // The fixture's `dash-app` entry (see `write_fixture`) resolves
    // net=allow, kvm=ask, postgres=deny; a non-interactive app must show
    // all three decided, with the `ask` one denied rather than ever
    // prompted.
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
    assert_eq!(outcome_for("net"), "allowed_by_policy");
    assert_eq!(outcome_for("kvm"), "denied_non_interactive");
    assert_eq!(outcome_for("postgres"), "denied_by_policy");

    for line in &lines {
        assert_eq!(line["app_id"], "dash-app");
        assert_eq!(line["kind"], "capability_request");
    }
    let _ = std::fs::remove_file(&path);
}

#[test]
fn forwards_sigterm_to_the_child_and_reports_its_conventional_exit_code() {
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
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
    let _guard = TEST_SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    set_fixture_env();
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
