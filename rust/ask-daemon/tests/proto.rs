//! Pins the wire schema to section 2 of the ask pane spec.
//!
//! Two things are checked, and they catch different mistakes.
//!
//! Round-tripping every frame through serde catches loss: a field that
//! serializes but does not deserialize, or a variant whose tag collides.
//! That alone would still pass if a field were renamed on both sides at
//! once, which is why the second half compares the serialized JSON against
//! the spec's own examples key for key. A rename that the pane would notice
//! fails here first.
//!
//! The examples use elided ids such as `"6f1a..."`. Real uuids stand in for
//! them, since the point is the shape rather than the value.

use std::fmt;
use std::path::PathBuf;

use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

use ask_daemon::proto::{
    decode_client_line, encode_server_line, BackendInfo, BackendState, BlockKind, ClientFrame,
    ConversationMeta, ErrorKind, EventBody, EventScope, PermissionDecision, PermissionScope,
    PlanState, RateLimit, SendBlock, SeqCounter, ServerEvent, StopReason, ToolOrigin,
    PROTOCOL_VERSION,
};

/// The thread every example belongs to.
fn conversation() -> Uuid {
    Uuid::parse_str("6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f").expect("fixed uuid parses")
}

/// The turn every example belongs to.
fn turn() -> Uuid {
    Uuid::parse_str("c3d0f1a2-b3c4-4d5e-9f60-71829304a5b6").expect("fixed uuid parses")
}

/// Encode, decode, and assert nothing changed on the way round.
fn round_trip_client(frame: &ClientFrame) {
    let line = serde_json::to_string(frame).expect("client frame serializes");
    assert!(!line.contains('\n'), "a frame must fit one line: {line}");
    let back = decode_client_line(&line).expect("our own output decodes");
    assert_eq!(frame, &back, "client frame changed across a round trip");
}

/// Encode, decode, and assert nothing changed on the way round.
fn round_trip_event(event: &ServerEvent) {
    let line = encode_server_line(event).expect("event serializes");
    assert!(line.ends_with('\n'), "the wire line must be terminated");
    assert_eq!(
        line.matches('\n').count(),
        1,
        "one object, one line: {line}"
    );
    let back: ServerEvent = serde_json::from_str(line.trim_end()).expect("our own output decodes");
    assert_eq!(event, &back, "event changed across a round trip");
}

/// Wrap a body the way its own scope says to.
fn wrap(body: EventBody) -> ServerEvent {
    match body.scope() {
        EventScope::Conversation => ServerEvent::persisted(4212, conversation(), body),
        EventScope::Connection => ServerEvent::ephemeral(body),
    }
}

/// One of every client frame the spec defines.
fn every_client_frame() -> Vec<ClientFrame> {
    vec![
        ClientFrame::Hello {
            protocol: PROTOCOL_VERSION,
            resume_seq: Some(4210),
        },
        ClientFrame::Hello {
            protocol: PROTOCOL_VERSION,
            resume_seq: None,
        },
        ClientFrame::List {
            limit: 50,
            before: None,
        },
        ClientFrame::List {
            limit: 10,
            before: Some(1_788_425_090_000),
        },
        ClientFrame::Open {
            conversation: conversation(),
            from_seq: None,
        },
        ClientFrame::Open {
            conversation: conversation(),
            from_seq: Some(4211),
        },
        ClientFrame::New {
            conversation: conversation(),
            backend: "claude-code".to_owned(),
            model: Some("opus".to_owned()),
            cwd: PathBuf::from("/home/matus/Dokumente/codeberg/personal/dots"),
            title: None,
        },
        ClientFrame::Send {
            conversation: conversation(),
            blocks: vec![
                SendBlock {
                    kind: BlockKind::Text,
                    text: Some("explain this crate".to_owned()),
                    path: None,
                    mime: None,
                },
                SendBlock {
                    kind: BlockKind::Image,
                    text: None,
                    path: Some(PathBuf::from("/run/user/1000/dots-ask/cap-3.png")),
                    mime: Some("image/png".to_owned()),
                },
                SendBlock {
                    kind: BlockKind::File,
                    text: None,
                    path: Some(PathBuf::from("/home/matus/rpc.rs")),
                    mime: Some("text/x-rust".to_owned()),
                },
            ],
        },
        ClientFrame::Interrupt {
            conversation: conversation(),
        },
        ClientFrame::Permission {
            conversation: conversation(),
            request: "29951f7f-70f1-4de6-be15-3d6939d2a806".to_owned(),
            decision: PermissionDecision::Allow,
            scope: PermissionScope::Once,
            updated_input: None,
            message: None,
        },
        ClientFrame::Permission {
            conversation: conversation(),
            request: "a8f8ddef-85af-4455-99e8-5e4990fc17d6".to_owned(),
            decision: PermissionDecision::Deny,
            scope: PermissionScope::Forever,
            updated_input: Some(json!({"file_path": "/tmp/a.txt"})),
            message: Some("denied by the spike driver".to_owned()),
        },
        ClientFrame::Delete {
            conversation: conversation(),
        },
    ]
}

/// One of every daemon event the spec defines.
fn every_event_body() -> Vec<EventBody> {
    vec![
        EventBody::Ready {
            protocol: PROTOCOL_VERSION,
            seq_head: 4211,
        },
        EventBody::TurnStart {
            turn: Some(turn()),
            backend: "claude-code".to_owned(),
            model: Some("claude-opus-5".to_owned()),
            started_ms: 1_788_425_059_000,
        },
        EventBody::TextDelta {
            turn: Some(turn()),
            block: 0,
            text: "The".to_owned(),
        },
        EventBody::ThinkingDelta {
            turn: Some(turn()),
            block: 0,
            text: String::new(),
            tokens: Some(50),
        },
        EventBody::CodeBlock {
            turn: Some(turn()),
            block: 1,
            language: Some("rust".to_owned()),
            source: "fn main() {}\n".to_owned(),
            html: None,
        },
        EventBody::ToolCall {
            turn: Some(turn()),
            call: "toolu_0147".to_owned(),
            name: "Write".to_owned(),
            display_name: Some("Write".to_owned()),
            summary: Some("a.txt".to_owned()),
            input: json!({"file_path": "/tmp/a.txt", "content": "alpha\n"}),
            origin: ToolOrigin::Harness,
        },
        EventBody::ToolResult {
            call: "toolu_0147".to_owned(),
            ok: false,
            content: "denied by the spike driver".to_owned(),
            truncated: false,
        },
        EventBody::PermissionRequest {
            request: "a8f8ddef".to_owned(),
            call: "toolu_0147".to_owned(),
            name: "Write".to_owned(),
            display_name: Some("Write".to_owned()),
            description: Some("a.txt".to_owned()),
            input: json!({"file_path": "/tmp/a.txt", "content": "alpha\n"}),
            suggestions: vec![json!({
                "type": "setMode", "mode": "acceptEdits", "destination": "session"
            })],
            withdrawn: false,
        },
        EventBody::Diff {
            call: "toolu_01TQ6".to_owned(),
            path: PathBuf::from("/tmp/b.txt"),
            old_text: String::new(),
            new_text: "beta\n".to_owned(),
            added: 1,
            removed: 0,
            html: None,
        },
        EventBody::Plan {
            turn: Some(turn()),
            title: Some("Rewrite the parser".to_owned()),
            markdown: "1. ...".to_owned(),
            state: PlanState::Proposed,
        },
        EventBody::Usage {
            turn: Some(turn()),
            input_tokens: 6,
            output_tokens: 811,
            cache_read_tokens: Some(83_100),
            cache_write_tokens: Some(12_489),
            thinking_tokens: Some(576),
            cost_usd: Some(0.186_745),
            rate_limit: Some(RateLimit {
                kind: "five_hour".to_owned(),
                status: "allowed".to_owned(),
                resets_at: 1_788_428_400,
            }),
        },
        EventBody::Usage {
            turn: Some(turn()),
            input_tokens: 6,
            output_tokens: 811,
            cache_read_tokens: None,
            cache_write_tokens: None,
            thinking_tokens: None,
            cost_usd: None,
            rate_limit: None,
        },
        EventBody::TurnEnd {
            turn: Some(turn()),
            stop: StopReason::EndTurn,
            text: Some("Created a.txt.".to_owned()),
            duration_ms: 15_673,
        },
        EventBody::TurnEnd {
            turn: Some(turn()),
            stop: StopReason::Interrupted,
            text: None,
            duration_ms: 2508,
        },
        EventBody::Error {
            kind: ErrorKind::Protocol,
            message: "unparseable control_request from claude 2.1.229".to_owned(),
            fatal: false,
        },
        EventBody::Error {
            kind: ErrorKind::BadRequest,
            message: "unknown op \"opne\"".to_owned(),
            fatal: false,
        },
        EventBody::Conversations {
            items: vec![ConversationMeta {
                id: conversation(),
                title: Some("explain this crate".to_owned()),
                backend: "claude-code".to_owned(),
                model: Some("claude-opus-5".to_owned()),
                cwd: PathBuf::from("/home/matus"),
                updated_ms: 1_788_425_090_000,
                turns: 3,
            }],
        },
        EventBody::Backends {
            items: vec![
                BackendInfo {
                    id: "claude-code".to_owned(),
                    label: "Claude Code".to_owned(),
                    state: BackendState::Ready,
                    models: vec!["opus".to_owned(), "sonnet".to_owned(), "haiku".to_owned()],
                    detail: None,
                },
                BackendInfo {
                    id: "ollama".to_owned(),
                    label: "Ollama".to_owned(),
                    state: BackendState::Unreachable,
                    models: Vec::new(),
                    detail: Some("connect 127.0.0.1:11434: refused".to_owned()),
                },
            ],
        },
    ]
}

#[test]
fn every_client_frame_round_trips() {
    for frame in every_client_frame() {
        round_trip_client(&frame);
    }
}

#[test]
fn every_daemon_event_round_trips() {
    for body in every_event_body() {
        round_trip_event(&wrap(body));
    }
}

#[test]
fn every_client_op_has_a_variant() {
    // A miss here means an op the spec lists has no Rust variant, which the
    // round trip above cannot notice because it only walks what exists.
    let ops: Vec<String> = every_client_frame()
        .iter()
        .map(|frame| {
            serde_json::to_value(frame).expect("frame serializes")["op"]
                .as_str()
                .expect("op is a string")
                .to_owned()
        })
        .collect();
    for op in [
        "hello",
        "list",
        "open",
        "new",
        "send",
        "interrupt",
        "permission",
        "delete",
    ] {
        assert!(
            ops.iter().any(|seen| seen == op),
            "no frame produced {op:?}"
        );
    }
}

#[test]
fn every_daemon_event_name_appears() {
    let names: Vec<String> = every_event_body()
        .iter()
        .map(|body| {
            serde_json::to_value(body).expect("body serializes")["event"]
                .as_str()
                .expect("event is a string")
                .to_owned()
        })
        .collect();
    for name in [
        "ready",
        "turn_start",
        "text_delta",
        "thinking_delta",
        "code_block",
        "tool_call",
        "tool_result",
        "permission_request",
        "diff",
        "plan",
        "usage",
        "turn_end",
        "error",
        "conversations",
        "backends",
    ] {
        assert!(
            names.iter().any(|seen| seen == name),
            "no body produced {name:?}"
        );
    }
}

#[test]
fn the_spec_client_examples_decode() {
    // Written the way the spec prints them, including the optional keys it
    // leaves out of a send block.
    let cases: Vec<(&str, ClientFrame)> = vec![
        (
            r#"{"op":"hello","protocol":1,"resume_seq":4210}"#,
            ClientFrame::Hello {
                protocol: 1,
                resume_seq: Some(4210),
            },
        ),
        (
            r#"{"op":"list","limit":50,"before":null}"#,
            ClientFrame::List {
                limit: 50,
                before: None,
            },
        ),
        (
            r#"{"op":"open","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f","from_seq":null}"#,
            ClientFrame::Open {
                conversation: conversation(),
                from_seq: None,
            },
        ),
        (
            r#"{"op":"interrupt","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f"}"#,
            ClientFrame::Interrupt {
                conversation: conversation(),
            },
        ),
        (
            r#"{"op":"delete","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f"}"#,
            ClientFrame::Delete {
                conversation: conversation(),
            },
        ),
        (
            r#"{"op":"new","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f",
               "backend":"claude-code","model":"opus",
               "cwd":"/home/matus/Dokumente/codeberg/personal/dots","title":null}"#,
            ClientFrame::New {
                conversation: conversation(),
                backend: "claude-code".to_owned(),
                model: Some("opus".to_owned()),
                cwd: PathBuf::from("/home/matus/Dokumente/codeberg/personal/dots"),
                title: None,
            },
        ),
        (
            r#"{"op":"send","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f","blocks":[
                 {"kind":"text","text":"explain this crate"},
                 {"kind":"image","mime":"image/png","path":"/run/user/1000/dots-ask/cap-3.png"},
                 {"kind":"file","mime":"text/x-rust","path":"/home/matus/rpc.rs"}]}"#,
            ClientFrame::Send {
                conversation: conversation(),
                blocks: vec![
                    SendBlock {
                        kind: BlockKind::Text,
                        text: Some("explain this crate".to_owned()),
                        path: None,
                        mime: None,
                    },
                    SendBlock {
                        kind: BlockKind::Image,
                        text: None,
                        path: Some(PathBuf::from("/run/user/1000/dots-ask/cap-3.png")),
                        mime: Some("image/png".to_owned()),
                    },
                    SendBlock {
                        kind: BlockKind::File,
                        text: None,
                        path: Some(PathBuf::from("/home/matus/rpc.rs")),
                        mime: Some("text/x-rust".to_owned()),
                    },
                ],
            },
        ),
        (
            r#"{"op":"permission","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f",
               "request":"29951f7f-70f1-4de6-be15-3d6939d2a806","decision":"allow",
               "scope":"once","updated_input":null,"message":null}"#,
            ClientFrame::Permission {
                conversation: conversation(),
                request: "29951f7f-70f1-4de6-be15-3d6939d2a806".to_owned(),
                decision: PermissionDecision::Allow,
                scope: PermissionScope::Once,
                updated_input: None,
                message: None,
            },
        ),
    ];

    let mut covered = Vec::new();
    for (line, expected) in cases {
        // The spec prints these across several lines for the page; the wire
        // rule is one object per line, so they are rejoined before decoding.
        let line = line.replace('\n', "").replace("               ", "");
        let frame = decode_client_line(&line).expect("the spec's own example decodes");
        assert_eq!(frame, expected, "decoding {line}");
        covered.push(
            serde_json::to_value(&frame).expect("frame serializes")["op"]
                .as_str()
                .expect("op is a string")
                .to_owned(),
        );
    }

    // The point of this test is that every op has a literal from the spec
    // behind it, so a gap in the coverage is itself a failure.
    for op in [
        "hello",
        "list",
        "open",
        "new",
        "send",
        "interrupt",
        "permission",
        "delete",
    ] {
        assert!(
            covered.iter().any(|seen| seen == op),
            "no spec example covers op {op:?}"
        );
    }
}

#[test]
fn a_send_block_may_omit_the_keys_its_kind_does_not_use() {
    let line = r#"{"op":"send","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f",
        "blocks":[{"kind":"text","text":"explain this crate"},
                  {"kind":"image","mime":"image/png","path":"/run/user/1000/cap-3.png"}]}"#;
    let ClientFrame::Send { blocks, .. } =
        decode_client_line(&line.replace('\n', "")).expect("the spec's own example decodes")
    else {
        panic!("decoded as the wrong op");
    };
    assert_eq!(blocks[0].path, None, "a text block carries no path");
    assert_eq!(blocks[1].text, None, "an image block carries no text");
    assert_eq!(blocks[0].mime, None, "an absent mime reads as null");
}

#[test]
fn the_spec_event_examples_match_the_wire() {
    let cases: Vec<(EventBody, Value)> = vec![
        (
            EventBody::Ready {
                protocol: 1,
                seq_head: 4211,
            },
            json!({"seq": null, "conversation": null, "event": "ready",
                   "protocol": 1, "seq_head": 4211}),
        ),
        (
            EventBody::TextDelta {
                turn: Some(turn()),
                block: 0,
                text: "The".to_owned(),
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "text_delta",
                   "turn": turn(), "block": 0, "text": "The"}),
        ),
        (
            EventBody::ThinkingDelta {
                turn: Some(turn()),
                block: 0,
                text: String::new(),
                tokens: Some(50),
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "thinking_delta",
                   "turn": turn(), "block": 0, "text": "", "tokens": 50}),
        ),
        (
            EventBody::ToolResult {
                call: "toolu_0147".to_owned(),
                ok: false,
                content: "denied by the spike driver".to_owned(),
                truncated: false,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "tool_result",
                   "call": "toolu_0147", "ok": false,
                   "content": "denied by the spike driver", "truncated": false}),
        ),
        (
            EventBody::TurnEnd {
                turn: Some(turn()),
                stop: StopReason::EndTurn,
                text: Some("Created a.txt.".to_owned()),
                duration_ms: 15_673,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "turn_end",
                   "turn": turn(), "stop": "end_turn", "text": "Created a.txt.",
                   "duration_ms": 15_673}),
        ),
        (
            EventBody::Error {
                kind: ErrorKind::BadRequest,
                message: "unknown op \"opne\"".to_owned(),
                fatal: false,
            },
            json!({"seq": null, "conversation": null, "event": "error",
                   "kind": "bad_request", "message": "unknown op \"opne\"",
                   "fatal": false}),
        ),
        (
            EventBody::TurnStart {
                turn: Some(turn()),
                backend: "claude-code".to_owned(),
                model: Some("claude-opus-5".to_owned()),
                started_ms: 1_788_425_059_000,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "turn_start",
                   "turn": turn(), "backend": "claude-code", "model": "claude-opus-5",
                   "started_ms": 1_788_425_059_000_u64}),
        ),
        (
            EventBody::CodeBlock {
                turn: Some(turn()),
                block: 1,
                language: Some("rust".to_owned()),
                source: "fn main() {}\n".to_owned(),
                html: Some("<pre class=\"code\">...</pre>".to_owned()),
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "code_block",
                   "turn": turn(), "block": 1, "language": "rust",
                   "source": "fn main() {}\n", "html": "<pre class=\"code\">...</pre>"}),
        ),
        (
            EventBody::ToolCall {
                turn: Some(turn()),
                call: "toolu_0147".to_owned(),
                name: "Write".to_owned(),
                display_name: Some("Write".to_owned()),
                summary: Some("a.txt".to_owned()),
                input: json!({"file_path": "/tmp/a.txt", "content": "alpha\n"}),
                origin: ToolOrigin::Harness,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "tool_call",
                   "turn": turn(), "call": "toolu_0147", "name": "Write",
                   "display_name": "Write", "summary": "a.txt",
                   "input": {"file_path": "/tmp/a.txt", "content": "alpha\n"},
                   "origin": "harness"}),
        ),
        (
            EventBody::PermissionRequest {
                request: "a8f8ddef".to_owned(),
                call: "toolu_0147".to_owned(),
                name: "Write".to_owned(),
                display_name: Some("Write".to_owned()),
                description: Some("a.txt".to_owned()),
                input: json!({"file_path": "/tmp/a.txt", "content": "alpha\n"}),
                suggestions: vec![json!({
                    "type": "setMode", "mode": "acceptEdits", "destination": "session"
                })],
                withdrawn: false,
            },
            json!({"seq": 4212, "conversation": conversation(),
                   "event": "permission_request", "request": "a8f8ddef",
                   "call": "toolu_0147", "name": "Write", "display_name": "Write",
                   "description": "a.txt",
                   "input": {"file_path": "/tmp/a.txt", "content": "alpha\n"},
                   "suggestions": [{"type": "setMode", "mode": "acceptEdits",
                                    "destination": "session"}],
                   "withdrawn": false}),
        ),
        (
            EventBody::Diff {
                call: "toolu_01TQ6".to_owned(),
                path: PathBuf::from("/tmp/b.txt"),
                old_text: String::new(),
                new_text: "beta\n".to_owned(),
                added: 1,
                removed: 0,
                html: Some("<table class=\"diff\">...</table>".to_owned()),
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "diff",
                   "call": "toolu_01TQ6", "path": "/tmp/b.txt", "old_text": "",
                   "new_text": "beta\n", "added": 1, "removed": 0,
                   "html": "<table class=\"diff\">...</table>"}),
        ),
        (
            EventBody::Plan {
                turn: Some(turn()),
                title: Some("Rewrite the parser".to_owned()),
                markdown: "1. ...".to_owned(),
                state: PlanState::Proposed,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "plan",
                   "turn": turn(), "title": "Rewrite the parser",
                   "markdown": "1. ...", "state": "proposed"}),
        ),
        (
            EventBody::Usage {
                turn: Some(turn()),
                input_tokens: 6,
                output_tokens: 811,
                cache_read_tokens: Some(83_100),
                cache_write_tokens: Some(12_489),
                thinking_tokens: Some(576),
                cost_usd: Some(0.186_745),
                rate_limit: Some(RateLimit {
                    kind: "five_hour".to_owned(),
                    status: "allowed".to_owned(),
                    resets_at: 1_788_428_400,
                }),
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "usage",
                   "turn": turn(), "input_tokens": 6, "output_tokens": 811,
                   "cache_read_tokens": 83_100, "cache_write_tokens": 12_489,
                   "thinking_tokens": 576, "cost_usd": 0.186_745,
                   "rate_limit": {"type": "five_hour", "status": "allowed",
                                  "resets_at": 1_788_428_400_u64}}),
        ),
        (
            EventBody::Error {
                kind: ErrorKind::Protocol,
                message: "unparseable control_request from claude 2.1.229".to_owned(),
                fatal: false,
            },
            json!({"seq": 4212, "conversation": conversation(), "event": "error",
                   "kind": "protocol",
                   "message": "unparseable control_request from claude 2.1.229",
                   "fatal": false}),
        ),
        (
            EventBody::Conversations {
                items: vec![ConversationMeta {
                    id: conversation(),
                    title: Some("explain this crate".to_owned()),
                    backend: "claude-code".to_owned(),
                    model: Some("claude-opus-5".to_owned()),
                    cwd: PathBuf::from("/home/matus"),
                    updated_ms: 1_788_425_090_000,
                    turns: 3,
                }],
            },
            json!({"seq": null, "conversation": null, "event": "conversations",
                   "items": [{"id": conversation(), "title": "explain this crate",
                              "backend": "claude-code", "model": "claude-opus-5",
                              "cwd": "/home/matus",
                              "updated_ms": 1_788_425_090_000_u64, "turns": 3}]}),
        ),
        (
            EventBody::Backends {
                items: vec![
                    BackendInfo {
                        id: "claude-code".to_owned(),
                        label: "Claude Code".to_owned(),
                        state: BackendState::Ready,
                        models: vec!["opus".to_owned(), "sonnet".to_owned(), "haiku".to_owned()],
                        detail: None,
                    },
                    BackendInfo {
                        id: "ollama".to_owned(),
                        label: "Ollama".to_owned(),
                        state: BackendState::Unreachable,
                        models: Vec::new(),
                        detail: Some("connect 127.0.0.1:11434: refused".to_owned()),
                    },
                ],
            },
            json!({"seq": null, "conversation": null, "event": "backends",
                   "items": [{"id": "claude-code", "label": "Claude Code",
                              "state": "ready",
                              "models": ["opus", "sonnet", "haiku"], "detail": null},
                             {"id": "ollama", "label": "Ollama",
                              "state": "unreachable", "models": [],
                              "detail": "connect 127.0.0.1:11434: refused"}]}),
        ),
    ];

    let mut covered = Vec::new();
    for (body, expected) in cases {
        let got = serde_json::to_value(wrap(body)).expect("event serializes");
        assert_eq!(got, expected, "wire shape drifted from the spec");
        covered.push(got["event"].as_str().expect("event is a string").to_owned());
    }

    // Same rule as the client half: a type with no spec literal behind it is
    // a type nothing would catch drifting.
    for name in [
        "ready",
        "turn_start",
        "text_delta",
        "thinking_delta",
        "code_block",
        "tool_call",
        "tool_result",
        "permission_request",
        "diff",
        "plan",
        "usage",
        "turn_end",
        "error",
        "conversations",
        "backends",
    ] {
        assert!(
            covered.iter().any(|seen| seen == name),
            "no spec example covers event {name:?}"
        );
    }
}

#[test]
fn the_rate_limit_field_is_spelled_type_on_the_wire() {
    let event = wrap(EventBody::Usage {
        turn: Some(turn()),
        input_tokens: 6,
        output_tokens: 811,
        cache_read_tokens: None,
        cache_write_tokens: None,
        thinking_tokens: None,
        cost_usd: None,
        rate_limit: Some(RateLimit {
            kind: "five_hour".to_owned(),
            status: "allowed".to_owned(),
            resets_at: 1_788_428_400,
        }),
    });
    let value = serde_json::to_value(&event).expect("event serializes");
    assert_eq!(
        value["rate_limit"],
        json!({"type": "five_hour", "status": "allowed", "resets_at": 1_788_428_400_u64}),
        "RateLimit.kind must reach the wire as \"type\""
    );
}

#[test]
fn an_ephemeral_reply_carries_null_seq_and_null_conversation() {
    for body in every_event_body() {
        if body.scope() != EventScope::Connection {
            continue;
        }
        let value = serde_json::to_value(ServerEvent::ephemeral(body)).expect("serializes");
        assert_eq!(value["seq"], Value::Null, "ephemeral seq must be null");
        assert_eq!(
            value["conversation"],
            Value::Null,
            "ephemeral conversation must be null"
        );
    }
}

#[test]
fn each_error_kind_has_the_scope_the_table_gives_it() {
    let cases = [
        (ErrorKind::BackendSpawn, EventScope::Conversation),
        (ErrorKind::Protocol, EventScope::Conversation),
        (ErrorKind::Auth, EventScope::Conversation),
        (ErrorKind::RateLimit, EventScope::Conversation),
        (ErrorKind::Cancelled, EventScope::Conversation),
        (ErrorKind::BadRequest, EventScope::Connection),
        (ErrorKind::Store, EventScope::Connection),
    ];
    for (kind, expected) in cases {
        assert_eq!(kind.scope(), expected, "wrong scope for {kind:?}");
        let body = EventBody::Error {
            kind,
            message: String::new(),
            fatal: false,
        };
        assert_eq!(
            body.scope(),
            expected,
            "the event body disagrees with its own kind"
        );
    }
}

/// Assert one variant of a closed value set reaches the wire as the spec
/// spells it.
fn spells<T: Serialize + fmt::Debug>(value: T, expected: &str) {
    assert_eq!(
        serde_json::to_value(&value).expect("a value set member serializes"),
        json!(expected),
        "{value:?} must reach the wire as {expected:?}"
    );
}

#[test]
fn every_closed_value_set_spells_itself_the_way_the_spec_does() {
    // Section 2 types these as `String` and then lists their legal values,
    // so they are Rust enums here. That is only safe while the wire bytes
    // are pinned: the round trips above are symmetric, so dropping a
    // rename_all would change what the pane reads and still pass every one
    // of them. This is the test that would fail instead.
    spells(ErrorKind::BackendSpawn, "backend_spawn");
    spells(ErrorKind::Protocol, "protocol");
    spells(ErrorKind::Auth, "auth");
    spells(ErrorKind::RateLimit, "rate_limit");
    spells(ErrorKind::Cancelled, "cancelled");
    spells(ErrorKind::BadRequest, "bad_request");
    spells(ErrorKind::Store, "store");

    spells(StopReason::EndTurn, "end_turn");
    spells(StopReason::ToolUse, "tool_use");
    spells(StopReason::Interrupted, "interrupted");
    spells(StopReason::MaxTokens, "max_tokens");
    spells(StopReason::Error, "error");

    spells(PermissionDecision::Allow, "allow");
    spells(PermissionDecision::Deny, "deny");

    spells(PermissionScope::Once, "once");
    spells(PermissionScope::Session, "session");
    spells(PermissionScope::Forever, "forever");

    spells(BlockKind::Text, "text");
    spells(BlockKind::Image, "image");
    spells(BlockKind::File, "file");

    spells(ToolOrigin::Harness, "harness");
    spells(ToolOrigin::Mcp, "mcp");

    spells(PlanState::Proposed, "proposed");
    spells(PlanState::Accepted, "accepted");
    spells(PlanState::Rejected, "rejected");

    spells(BackendState::Ready, "ready");
    spells(BackendState::Unconfigured, "unconfigured");
    spells(BackendState::Unreachable, "unreachable");
}

#[test]
fn a_closed_value_set_refuses_a_value_the_spec_does_not_list() {
    // The other half of the enum decision: a backend or a client cannot
    // invent a value the pane has no branch for.
    let frame = r#"{"op":"permission","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f",
        "request":"r","decision":"maybe","scope":"once",
        "updated_input":null,"message":null}"#;
    assert!(
        decode_client_line(&frame.replace('\n', "")).is_err(),
        "decision is allow or deny, and nothing else"
    );

    let scope = r#"{"op":"permission","conversation":"6f1a0c2e-4a1b-4c3d-8e5f-9a0b1c2d3e4f",
        "request":"r","decision":"allow","scope":"for a bit",
        "updated_input":null,"message":null}"#;
    assert!(
        decode_client_line(&scope.replace('\n', "")).is_err(),
        "scope is once, session or forever, and nothing else"
    );
}

#[test]
fn an_unknown_op_is_named_back_to_the_client() {
    let message = decode_client_line(r#"{"op":"opne","protocol":1}"#)
        .expect_err("an op the daemon does not have must be rejected");
    assert_eq!(message, "unknown op \"opne\"");
}

#[test]
fn a_line_with_no_op_says_so() {
    let message =
        decode_client_line(r#"{"protocol":1}"#).expect_err("a frame with no op is rejected");
    assert_eq!(message, "frame has no \"op\" field");
}

#[test]
fn a_line_that_is_not_json_is_rejected_without_naming_a_rust_type() {
    let message = decode_client_line("not json at all").expect_err("garbage is rejected");
    assert!(
        message.starts_with("malformed frame: "),
        "unhelpful message: {message}"
    );
}

#[test]
fn a_known_op_with_a_bad_field_names_the_op() {
    let message = decode_client_line(r#"{"op":"open","conversation":"not-a-uuid"}"#)
        .expect_err("a bad uuid is rejected");
    assert!(
        message.starts_with("op \"open\" is missing or has a bad field: "),
        "unhelpful message: {message}"
    );
}

#[test]
fn a_list_frame_defaults_its_limit_to_fifty() {
    let frame = decode_client_line(r#"{"op":"list"}"#).expect("limit is optional");
    assert_eq!(
        frame,
        ClientFrame::List {
            limit: 50,
            before: None
        }
    );
}

#[test]
fn only_hello_and_list_may_omit_a_conversation() {
    for frame in every_client_frame() {
        let named = frame.conversation().is_some();
        let expected = !matches!(frame, ClientFrame::Hello { .. } | ClientFrame::List { .. });
        assert_eq!(named, expected, "wrong conversation rule for {frame:?}");
    }
}

#[test]
fn a_block_must_carry_what_its_kind_needs() {
    let empty_text = SendBlock {
        kind: BlockKind::Text,
        text: None,
        path: None,
        mime: None,
    };
    assert!(empty_text.validate().is_err(), "a text block needs text");

    let pathless_image = SendBlock {
        kind: BlockKind::Image,
        text: Some("caption".to_owned()),
        path: None,
        mime: None,
    };
    assert!(
        pathless_image.validate().is_err(),
        "an attachment needs a path"
    );

    let good = SendBlock {
        kind: BlockKind::File,
        text: None,
        path: Some(PathBuf::from("/tmp/x.rs")),
        mime: None,
    };
    assert!(good.validate().is_ok(), "a file block with a path is fine");
}

#[test]
fn the_seq_counter_is_dense_and_starts_at_one() {
    let mut seq = SeqCounter::default();
    assert_eq!(seq.head(), 0, "nothing persisted means head 0");
    let handed: Vec<u64> = (0..5).map(|_| seq.allocate()).collect();
    assert_eq!(
        handed,
        vec![1, 2, 3, 4, 5],
        "the counter must have no holes"
    );
    assert_eq!(seq.head(), 5);
}

#[test]
fn the_seq_counter_resumes_above_the_stored_head() {
    let mut seq = SeqCounter::resuming_from(4211);
    assert_eq!(seq.head(), 4211);
    assert_eq!(seq.allocate(), 4212, "a restart must not reuse a seq");
}
