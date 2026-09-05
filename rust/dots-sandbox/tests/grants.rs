//! Integration tests for `grants::grant_argv` (the pure `machinectl`
//! command-line builder) and `grants::parse_list_output` (interpreting a
//! captured invocation) — the parts of grant management that don't
//! require an actual running sandbox machine, which this environment has
//! no way to produce (`systemd-nsresourced` is not enabled here; see
//! `tests/live_grant.rs`).
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{ExitStatus, Output};

use dots_sandbox::grants::{
    grant_argv, parse_list_output, revoke_path_grant_unsupported, GrantError, GrantKind,
};

fn exit_status(raw: i32) -> ExitStatus {
    ExitStatus::from_raw(raw)
}

fn output(status: ExitStatus, stdout: &str, stderr: &str) -> Output {
    Output {
        status,
        stdout: stdout.as_bytes().to_vec(),
        stderr: stderr.as_bytes().to_vec(),
    }
}

#[test]
fn path_grant_defaults_to_a_plain_readwrite_bind() {
    let kind = GrantKind::Path {
        host_path: PathBuf::from("/home/user/Downloads"),
        sandbox_path: None,
        read_only: false,
        mkdir: false,
    };
    assert_eq!(
        grant_argv("dots-firefox", &kind),
        vec!["--user", "bind", "dots-firefox", "/home/user/Downloads"]
    );
}

#[test]
fn path_grant_with_destination_read_only_and_mkdir_sets_every_flag() {
    let kind = GrantKind::Path {
        host_path: PathBuf::from("/home/user/Documents"),
        sandbox_path: Some(PathBuf::from("/run/host/Documents")),
        read_only: true,
        mkdir: true,
    };
    assert_eq!(
        grant_argv("dots-office", &kind),
        vec![
            "--user",
            "--read-only",
            "--mkdir",
            "bind",
            "dots-office",
            "/home/user/Documents",
            "/run/host/Documents",
        ]
    );
}

#[test]
fn volume_grant_passes_the_spec_through_unparsed() {
    let kind = GrantKind::Volume {
        spec: "some-provider:some-volume:ro".to_owned(),
    };
    assert_eq!(
        grant_argv("dots-vm-app", &kind),
        vec![
            "--user",
            "bind-volume",
            "dots-vm-app",
            "some-provider:some-volume:ro"
        ]
    );
}

#[test]
fn every_grant_argv_leads_with_user_scope() {
    // The one non-negotiable: system-scope `machinectl bind`/`bind-volume`
    // trigger an admin polkit prompt on every launch (see module docs).
    // `--user` must be first no matter what kind of grant this is.
    let path_argv = grant_argv(
        "m",
        &GrantKind::Path {
            host_path: PathBuf::from("/a"),
            sandbox_path: None,
            read_only: false,
            mkdir: false,
        },
    );
    let volume_argv = grant_argv(
        "m",
        &GrantKind::Volume {
            spec: "p:v".to_owned(),
        },
    );
    assert_eq!(path_argv[0], "--user");
    assert_eq!(volume_argv[0], "--user");
}

#[test]
fn parse_list_output_returns_the_parsed_json_on_success() {
    let out = output(exit_status(0), "[]", "");
    let value = parse_list_output(&out).expect("empty JSON array is valid output");
    assert_eq!(value, serde_json::json!([]));
}

#[test]
fn parse_list_output_surfaces_exit_status_and_stderr_on_failure() {
    // `1 << 8` is the wait(2) encoding for "exited with code 1" used by
    // `ExitStatusExt::from_raw` on Linux.
    let out = output(
        exit_status(1 << 8),
        "",
        "Could not activate remote peer 'org.freedesktop.machine1'",
    );
    let err = parse_list_output(&out).expect_err("a non-zero exit must not be treated as success");
    match err {
        GrantError::MachinectlFailed { status, stderr } => {
            assert_eq!(status, Some(1));
            assert!(stderr.contains("org.freedesktop.machine1"), "{stderr}");
        }
        other => panic!("expected MachinectlFailed, got {other:?}"),
    }
}

#[test]
fn parse_list_output_rejects_malformed_json_even_on_a_successful_exit() {
    let out = output(exit_status(0), "not json", "");
    let err = parse_list_output(&out).expect_err("garbage stdout must not be silently accepted");
    assert!(matches!(err, GrantError::MalformedJson(_)));
}

#[test]
fn revoking_a_path_grant_is_refused_with_an_explanatory_diagnostic_not_a_silent_success() {
    let err = revoke_path_grant_unsupported();
    let message = err.to_string();
    assert!(
        message.contains("cannot be revoked live"),
        "message should explain the limitation, got: {message}"
    );
}
