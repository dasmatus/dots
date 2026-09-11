//! End-to-end tests for `global-settings serve`'s JSON-RPC 2.0 conversation
//! with the beamenu-canvas sidecar (protocol v1): line-delimited JSON over
//! stdio. Drives the real subprocess rather than extracted functions, so a
//! framing bug (missing newline, wrong flush) would actually be caught.

use global_settings::menu::ITEMS;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};

struct Serve {
    child: Child,
    // `None` after `close_stdin`. Models the canvas process exiting/crashing
    // without ever sending `shutdown`.
    stdin: Option<ChildStdin>,
    stdout: BufReader<std::process::ChildStdout>,
}

impl Serve {
    fn spawn(file: &std::path::Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_global-settings"))
            .args(["serve", "--file"])
            .arg(file)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("binary must spawn");
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            stdin: Some(stdin),
            stdout,
        }
    }

    fn recv(&mut self) -> serde_json::Value {
        let mut line = String::new();
        let n = self.stdout.read_line(&mut line).expect("stdout readable");
        assert!(n > 0, "child closed stdout without sending a line");
        serde_json::from_str(line.trim_end()).unwrap_or_else(|e| panic!("not JSON: {line:?}: {e}"))
    }

    fn send(&mut self, value: &serde_json::Value) {
        self.send_raw(&value.to_string());
    }

    /// Write a literal line as-is, unlike `send` this does not require valid
    /// JSON. Lets a test feed the worker garbage on the wire.
    fn send_raw(&mut self, line: &str) {
        let stdin = self.stdin.as_mut().expect("stdin already closed");
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
    }

    /// Close stdin (simulating the canvas process exiting/crashing) without
    /// sending `shutdown`.
    fn close_stdin(&mut self) {
        self.stdin = None;
    }

    fn finish(mut self) -> std::process::ExitStatus {
        self.send(&serde_json::json!({ "jsonrpc": "2.0", "method": "shutdown" }));
        self.child.wait().unwrap()
    }

    /// Send `shutdown`, then collect every remaining line up to EOF. Lets a
    /// test assert nothing extra arrived after the point it stopped reading.
    fn finish_collecting_remainder(mut self) -> (std::process::ExitStatus, Vec<String>) {
        self.send(&serde_json::json!({ "jsonrpc": "2.0", "method": "shutdown" }));
        let mut rest = Vec::new();
        loop {
            let mut line = String::new();
            let n = self.stdout.read_line(&mut line).expect("stdout readable");
            if n == 0 {
                break;
            }
            rest.push(line.trim_end().to_string());
        }
        (self.child.wait().unwrap(), rest)
    }
}

fn temp_file(name: &str, content: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("{name}-{}.nix", std::process::id()));
    std::fs::write(&path, content).unwrap();
    path
}

#[test]
fn serve_renders_the_form_on_start() {
    let path = temp_file(
        "serve-start",
        "{\n  hostname = \"box\";\n  aiCodex = false;\n}\n",
    );
    let mut serve = Serve::spawn(&path);
    let msg = serve.recv();
    assert_eq!(msg["method"], "ui.render");
    let tree = &msg["params"]["tree"];
    assert_eq!(tree["type"], "form");
    assert_eq!(tree["submit_label"], "Save");
    let fields = tree["fields"].as_array().unwrap();
    // ITEMS.len(), not a literal: the render tree is generated from that same
    // table, so a count here only restates it and breaks whenever a row lands.
    assert_eq!(fields.len(), ITEMS.len());
    let hostname = fields.iter().find(|f| f["key"] == "hostname").unwrap();
    assert_eq!(hostname["type"], "text");
    assert_eq!(hostname["value"], "box");
    let codex = fields.iter().find(|f| f["key"] == "aiCodex").unwrap();
    assert_eq!(codex["type"], "checkbox");
    assert_eq!(codex["value"], false);

    let status = serve.finish();
    assert!(status.success());
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn form_submit_saves_and_re_renders() {
    let path = temp_file("serve-submit", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();

    serve.send(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "form.submit",
        "params": { "values": { "hostname": "renamed" } },
    }));

    let result = serve.recv();
    assert_eq!(result["id"], 1);
    assert_eq!(result["result"], serde_json::json!({}));

    let render = serve.recv();
    assert_eq!(render["method"], "ui.render");
    let hostname = render["params"]["tree"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == "hostname")
        .unwrap();
    assert_eq!(hostname["value"], "renamed");

    let status = serve.finish();
    assert!(status.success());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("hostname = \"renamed\";"));
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn form_submit_validation_failure_reports_error_and_does_not_save() {
    let path = temp_file("serve-invalid", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();

    serve.send(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 42,
        "method": "form.submit",
        "params": { "values": { "hostname": "UpperCase" } },
    }));

    let response = serve.recv();
    assert_eq!(response["id"], 42);
    assert!(response["error"]["message"].is_string(), "{response}");
    assert!(response.get("result").is_none(), "{response}");

    let status = serve.finish();
    assert!(status.success());
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "{\n  hostname = \"box\";\n}\n"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn form_submit_with_no_changes_skips_the_re_render() {
    let path = temp_file("serve-nochange", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();

    serve.send(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 7,
        "method": "form.submit",
        "params": { "values": { "hostname": "box" } },
    }));

    let response = serve.recv();
    assert_eq!(response["id"], 7);
    assert_eq!(response["result"], serde_json::json!({}));

    // Nothing changed, so serve must not re-render: draining to EOF after
    // shutdown must not turn up a stray ui.render line.
    let (status, remainder) = serve.finish_collecting_remainder();
    assert!(status.success());
    assert!(
        remainder.is_empty(),
        "unexpected extra output: {remainder:?}"
    );
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn shutdown_exits_cleanly() {
    let path = temp_file("serve-shutdown", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();
    let status = serve.finish();
    assert!(status.success());
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn survives_a_malformed_line_between_valid_requests() {
    let path = temp_file("serve-garbage", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();

    serve.send(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "form.submit",
        "params": { "values": { "hostname": "first" } },
    }));
    let result1 = serve.recv();
    assert_eq!(result1["id"], 1);
    assert_eq!(result1["result"], serde_json::json!({}));
    let render1 = serve.recv();
    assert_eq!(render1["method"], "ui.render");

    // A garbage line between two valid requests must not kill the worker. If
    // it did, the second request below would never get a response and
    // `recv` would panic on a closed stdout instead.
    serve.send_raw("not json");

    serve.send(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "form.submit",
        "params": { "values": { "hostname": "second" } },
    }));
    let result2 = serve.recv();
    assert_eq!(result2["id"], 2);
    assert_eq!(result2["result"], serde_json::json!({}));
    let render2 = serve.recv();
    assert_eq!(render2["method"], "ui.render");
    let hostname = render2["params"]["tree"]["fields"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == "hostname")
        .unwrap();
    assert_eq!(hostname["value"], "second");

    let status = serve.finish();
    assert!(status.success());
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn eof_without_shutdown_exits_cleanly() {
    let path = temp_file("serve-eof", "{\n  hostname = \"box\";\n}\n");
    let mut serve = Serve::spawn(&path);
    let _initial_render = serve.recv();

    // Close stdin (the canvas process exiting/crashing) without ever sending
    // `shutdown`. The worker must still notice EOF on stdin and exit 0
    // rather than hang waiting for a line that will never arrive.
    serve.close_stdin();
    let status = serve.child.wait().unwrap();
    assert!(status.success());
    std::fs::remove_file(&path).unwrap();
}
