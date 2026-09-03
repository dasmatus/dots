//! Replays the recorded `claude` stream and asserts the events it produces.
//!
//! `tests/fixtures/claude-stream.jsonl` is the capture section 1 of the spec
//! was written from: 131 lines, three user turns against a scratch
//! directory, with the first `Write` denied, the second allowed and the third
//! interrupted while its permission request was still open. All three
//! outcomes in one file.
//!
//! The interface is undocumented and carries no compatibility promise, so
//! this file is what makes a `claude` upgrade fail loudly instead of the pane
//! going quiet. No process is started and no network is touched: the decoder
//! holds no I/O, so the fixture is fed to it a line at a time.

use std::path::PathBuf;

use serde_json::{json, Value};
use uuid::Uuid;

use ask_daemon::backend::claude_code::{argv, permission_response, resume_argv, StreamDecoder};
use ask_daemon::proto::{ErrorKind, EventBody, PermissionDecision, StopReason};

/// The recorded stream.
const FIXTURE: &str = include_str!("fixtures/claude-stream.jsonl");

/// Everything the fixture produces, in order, plus everything written back.
struct Replay {
    events: Vec<EventBody>,
    replies: Vec<Value>,
}

/// Feed the whole fixture through a fresh decoder.
fn replay() -> Replay {
    let mut decoder = StreamDecoder::new(Some("opus".to_owned()));
    let mut events = Vec::new();
    let mut replies = Vec::new();
    for line in FIXTURE.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let produced = decoder.push(line);
        events.extend(produced.events);
        replies.extend(produced.replies);
    }
    Replay { events, replies }
}

/// The `event` tag of each body, which is how the order is asserted.
fn names(events: &[EventBody]) -> Vec<String> {
    events
        .iter()
        .map(|body| {
            serde_json::to_value(body).expect("a body serializes")["event"]
                .as_str()
                .expect("event is a string")
                .to_owned()
        })
        .collect()
}

#[test]
fn the_argv_carries_the_flag_that_is_not_in_help() {
    // Task 0 measured this: without --permission-prompt-tool the CLI
    // resolves permissions internally, emits system/permission_denied, and
    // no control_request ever arrives, so the approval UI never fires. It
    // does not appear in `claude --help`, which is exactly why it is easy to
    // drop as unrecognised and why this is a test.
    let session = Uuid::new_v4();
    let args = argv(session, Some("opus"));
    let pairs: Vec<(&String, &String)> = args.iter().zip(args.iter().skip(1)).collect();
    assert!(
        pairs.contains(&(&"--permission-prompt-tool".to_owned(), &"stdio".to_owned())),
        "the hidden flag is mandatory: {args:?}"
    );
    assert!(
        pairs.contains(&(&"--permission-mode".to_owned(), &"manual".to_owned())),
        "manual normalizes to default inside the bundle: {args:?}"
    );
    assert!(
        pairs.contains(&(&"--session-id".to_owned(), &session.to_string())),
        "the daemon mints the session id: {args:?}"
    );
    assert!(
        pairs.contains(&(&"--model".to_owned(), &"opus".to_owned())),
        "the thread's model reaches the CLI: {args:?}"
    );
    assert!(args.contains(&"--include-partial-messages".to_owned()));
    assert!(
        args.contains(&"stream-json".to_owned()),
        "both formats are stream-json: {args:?}"
    );
}

#[test]
fn the_daemon_never_asks_the_cli_to_skip_permissions() {
    // Section 5 forbids both by name. A build that acquired either would be
    // a build with no approval gate at all.
    for args in [
        argv(Uuid::new_v4(), None),
        resume_argv(Uuid::new_v4(), None),
    ] {
        assert!(
            !args
                .iter()
                .any(|arg| arg == "--dangerously-skip-permissions"),
            "{args:?}"
        );
        assert!(
            !args.iter().any(|arg| arg == "bypassPermissions"),
            "{args:?}"
        );
    }
}

#[test]
fn a_thread_with_no_model_passes_no_model_flag() {
    let args = argv(Uuid::new_v4(), None);
    assert!(
        !args.iter().any(|arg| arg == "--model"),
        "null means the backend's own default: {args:?}"
    );
}

#[test]
fn resuming_names_the_session_it_resumes() {
    let session = Uuid::new_v4();
    let args = resume_argv(session, Some("sonnet"));
    let pairs: Vec<(&String, &String)> = args.iter().zip(args.iter().skip(1)).collect();
    assert!(pairs.contains(&(&"--resume".to_owned(), &session.to_string())));
}

#[test]
fn the_recorded_session_needs_no_reply_the_decoder_invents() {
    // Every control request in the fixture is a can_use_tool, and those are
    // answered by a person through the pane rather than by the decoder. A
    // reply appearing here would mean the daemon had decided a permission
    // question on its own, which is the one thing the approval gate exists
    // to prevent.
    let replay = replay();
    assert!(
        replay.replies.is_empty(),
        "the decoder answered something nobody asked it to: {:?}",
        replay.replies
    );
}

#[test]
fn the_fixture_opens_three_turns_and_closes_three() {
    // result is the turn boundary, not the session boundary: the process
    // stayed alive on one session_id across all three.
    let replay = replay();
    let names = names(&replay.events);
    assert_eq!(
        names.iter().filter(|name| *name == "turn_start").count(),
        3,
        "one system/init per user turn"
    );
    assert_eq!(
        names.iter().filter(|name| *name == "turn_end").count(),
        3,
        "one result per user turn"
    );
}

#[test]
fn the_three_permission_outcomes_all_come_through() {
    let replay = replay();

    let requests: Vec<(&str, &str, bool)> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::PermissionRequest {
                request,
                name,
                withdrawn,
                ..
            } => Some((request.as_str(), name.as_str(), *withdrawn)),
            _ => None,
        })
        .collect();
    assert_eq!(
        requests.len(),
        4,
        "three can_use_tool requests plus the withdrawal of the third: {requests:?}"
    );
    assert_eq!(requests[0].0, "a8f8ddef-85af-4455-99e8-5e4990fc17d6");
    assert_eq!(requests[0].1, "Write");
    assert!(!requests[0].2);
    assert_eq!(requests[1].0, "29951f7f-70f1-4de6-be15-3d6939d2a806");
    assert_eq!(requests[2].0, "9dc45437-01a3-4d31-b99e-9957760c4e01");
    assert!(!requests[2].2, "the third opens like the others");
    assert_eq!(
        requests[3].0, "9dc45437-01a3-4d31-b99e-9957760c4e01",
        "and is re-emitted when the CLI withdraws it"
    );
    assert!(
        requests[3].2,
        "the pane dismisses the prompt on withdrawn: true"
    );

    let results: Vec<(&str, bool, &str)> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::ToolResult {
                call, ok, content, ..
            } => Some((call.as_str(), *ok, content.as_str())),
            _ => None,
        })
        .collect();
    assert_eq!(results.len(), 3, "one per outcome: {results:?}");

    // Denied. is_error true, and the content is the message the driver sent
    // back, verbatim.
    assert_eq!(results[0].0, "toolu_0147PnvrgYvQkbYPA9HjHzod");
    assert!(!results[0].1);
    assert_eq!(results[0].2, "denied by the spike driver");

    // Allowed. This is the line with no is_error key at all, which is the
    // rule a decoder gets wrong by keying off is_error alone.
    assert_eq!(results[1].0, "toolu_01TQ6VDPu86gfwQs5NKnh6fa");
    assert!(results[1].1, "a missing is_error means success");
    assert!(results[1].2.starts_with("File created successfully"));

    // Interrupted. Same key set as the denied one, different values, and the
    // content is the CLI's own canned rejection rather than anything the
    // client wrote.
    assert_eq!(results[2].0, "toolu_01LdwiiJ1YRdfULydH5QN8Wu");
    assert!(!results[2].1);
    assert!(results[2].2.starts_with("The user doesn't want to proceed"));
}

#[test]
fn an_interrupted_turn_ends_interrupted_and_raises_no_error() {
    // The CLI marks a client interrupt as a failure: the third result has
    // subtype error_during_execution, is_error true and a populated errors
    // array. The daemon does not, because the client asked for it.
    // terminal_reason is the field that separates the two.
    let replay = replay();
    let stops: Vec<StopReason> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::TurnEnd { stop, .. } => Some(*stop),
            _ => None,
        })
        .collect();
    assert_eq!(
        stops,
        vec![
            StopReason::EndTurn,
            StopReason::EndTurn,
            StopReason::Interrupted
        ],
        "aborted_tools is an interrupt, not a failure"
    );

    let errors: Vec<&ErrorKind> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::Error { kind, .. } => Some(kind),
            _ => None,
        })
        .collect();
    assert!(
        errors.is_empty(),
        "a client-driven interrupt raises no error at all: {errors:?}"
    );
}

#[test]
fn an_interrupted_turn_carries_no_summary_text() {
    let replay = replay();
    let texts: Vec<Option<&str>> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::TurnEnd { text, .. } => Some(text.as_deref()),
            _ => None,
        })
        .collect();
    assert!(texts[0].is_some(), "a completed turn summarizes itself");
    assert_eq!(
        texts[2], None,
        "the interrupted result has no result text to carry"
    );
}

#[test]
fn thinking_arrives_with_no_text_and_only_an_estimate() {
    // All twelve thinking_delta events carry an empty string. The only real
    // signal on this harness is the token estimate, which is why the pane
    // must treat an empty thinking block as normal rather than as a bug.
    let replay = replay();
    let thinking: Vec<(&str, Option<u32>)> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::ThinkingDelta { text, tokens, .. } => Some((text.as_str(), *tokens)),
            _ => None,
        })
        .collect();
    assert_eq!(thinking.len(), 12, "the fixture holds twelve");
    assert!(
        thinking.iter().all(|(text, _)| text.is_empty()),
        "harness thinking text is always empty"
    );
    assert!(
        thinking.iter().any(|(_, tokens)| tokens.is_some()),
        "and the estimate is the part that is real"
    );
}

#[test]
fn the_tool_call_carries_the_settled_arguments() {
    // content_block_start names the tool with an empty input; the settled
    // assistant line is where the arguments arrive.
    let replay = replay();
    let calls: Vec<(&str, &str, Option<&str>)> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::ToolCall {
                call,
                name,
                summary,
                input,
                ..
            } => {
                assert!(
                    input.get("file_path").is_some(),
                    "the settled arguments are on the event: {input}"
                );
                Some((call.as_str(), name.as_str(), summary.as_deref()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(calls.len(), 3, "three writes: {calls:?}");
    assert!(calls.iter().all(|(_, name, _)| *name == "Write"));
    assert!(
        calls[0].2.is_some_and(|summary| summary.ends_with("a.txt")),
        "the summary is the argument the pane shows collapsed: {calls:?}"
    );
}

#[test]
fn the_allowed_write_produces_a_diff_and_the_refused_ones_do_not() {
    // The CLI emits no diff event of its own, so the daemon always builds
    // it. The fixture's one structuredPatch is empty, because Write on a
    // file that did not exist has nothing to diff against, so this is the
    // branch built from the file's own before and after.
    let replay = replay();
    let diffs: Vec<(&PathBuf, &str, &str, u32, u32)> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::Diff {
                path,
                old_text,
                new_text,
                added,
                removed,
                ..
            } => Some((path, old_text.as_str(), new_text.as_str(), *added, *removed)),
            _ => None,
        })
        .collect();
    assert_eq!(
        diffs.len(),
        1,
        "only the write that actually ran changed a file: {diffs:?}"
    );
    assert!(diffs[0].0.ends_with("b.txt"));
    assert_eq!(diffs[0].1, "", "the file did not exist before");
    assert_eq!(diffs[0].2, "beta\n");
    assert_eq!(
        (diffs[0].3, diffs[0].4),
        (1, 0),
        "one line added, none gone"
    );
}

#[test]
fn a_diff_carries_rendered_html() {
    let replay = replay();
    let html = replay
        .events
        .iter()
        .find_map(|body| match body {
            EventBody::Diff { html, .. } => html.clone(),
            _ => None,
        })
        .expect("the allowed write produced a diff");
    assert!(html.starts_with("<pre class=\"diff\">"), "{html}");
    assert!(html.contains("beta"), "{html}");
}

#[test]
fn usage_folds_in_the_rate_limit_the_stream_reported() {
    // rate_limit_event arrives once, between two turns, and section 3 gives
    // that column to claude-code alone.
    let replay = replay();
    let with_limit = replay
        .events
        .iter()
        .filter(|body| {
            matches!(
                body,
                EventBody::Usage {
                    rate_limit: Some(_),
                    ..
                }
            )
        })
        .count();
    assert!(
        with_limit > 0,
        "the rate limit must reach the usage events after it"
    );

    let EventBody::Usage {
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        thinking_tokens,
        cost_usd,
        ..
    } = replay
        .events
        .iter()
        .rfind(|body| {
            matches!(
                body,
                EventBody::Usage {
                    cost_usd: Some(_),
                    ..
                }
            )
        })
        .expect("a result line carries total_cost_usd")
    else {
        unreachable!("filtered to Usage");
    };
    assert_eq!(*input_tokens, 2);
    assert_eq!(*output_tokens, 167);
    assert_eq!(*cache_read_tokens, Some(32_752));
    assert_eq!(*cache_write_tokens, Some(377));
    assert_eq!(*thinking_tokens, Some(0));
    assert_eq!(*cost_usd, Some(0.279_338_999_999_999_95));
}

#[test]
fn no_event_carries_a_turn_the_backend_invented() {
    // The turn id is minted in session.rs and never leaves the daemon, so an
    // adapter must emit None and let Session::adopt stamp it.
    for body in replay().events {
        let value = serde_json::to_value(&body).expect("a body serializes");
        if let Some(turn) = value.get("turn") {
            assert_eq!(
                turn,
                &Value::Null,
                "an adapter must not mint a turn: {value}"
            );
        }
    }
}

#[test]
fn every_line_of_the_fixture_decodes_without_a_protocol_error() {
    // A protocol error here means a shape this build has no branch for,
    // which after a claude upgrade is exactly what would make the pane go
    // quiet. The fixture is the version the spec was written against, so it
    // must decode clean.
    let replay = replay();
    let complaints: Vec<&str> = replay
        .events
        .iter()
        .filter_map(|body| match body {
            EventBody::Error {
                kind: ErrorKind::Protocol,
                message,
                ..
            } => Some(message.as_str()),
            _ => None,
        })
        .collect();
    assert!(complaints.is_empty(), "{complaints:?}");
}

#[test]
fn a_line_that_is_not_json_becomes_a_protocol_error_rather_than_a_silent_drop() {
    let mut decoder = StreamDecoder::new(None);
    let produced = decoder.push("this is not json at all");
    assert!(matches!(
        produced.events.as_slice(),
        [EventBody::Error {
            kind: ErrorKind::Protocol,
            fatal: false,
            ..
        }]
    ));
    assert!(produced.replies.is_empty());
}

#[test]
fn an_unknown_line_type_becomes_a_protocol_error() {
    let mut decoder = StreamDecoder::new(None);
    let produced = decoder.push(r#"{"type":"something_new_in_2_2_0"}"#);
    let [EventBody::Error { kind, message, .. }] = produced.events.as_slice() else {
        panic!("expected one error, got {:?}", produced.events);
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert!(
        message.contains("something_new_in_2_2_0"),
        "the message names what arrived: {message}"
    );
}

#[test]
fn a_control_request_it_cannot_answer_is_refused_rather_than_ignored() {
    // An unanswered control request stalls the turn with no visible cause,
    // and the CLI can send three subtypes of which only can_use_tool was
    // exercised. So the other two get an explicit deny and an error the pane
    // can show.
    let mut decoder = StreamDecoder::new(None);
    let produced = decoder.push(
        r#"{"type":"control_request","request_id":"abc",
            "request":{"subtype":"elicitation","message":"who are you"}}"#,
    );

    let [EventBody::Error { kind, message, .. }] = produced.events.as_slice() else {
        panic!("expected one error, got {:?}", produced.events);
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert!(message.contains("elicitation"), "{message}");

    assert_eq!(produced.replies.len(), 1, "the turn must not stall");
    let reply = &produced.replies[0];
    assert_eq!(reply["type"], json!("control_response"));
    assert_eq!(
        reply["response"]["request_id"],
        json!("abc"),
        "the id is echoed inside the response object, not at the top level"
    );
    assert_eq!(reply["response"]["subtype"], json!("success"));
    assert_eq!(reply["response"]["response"]["behavior"], json!("deny"));
    assert_eq!(
        reply.get("request_id"),
        None,
        "the top level carries only type"
    );
}

#[test]
fn a_withdrawn_request_stops_accepting_a_decision() {
    // Section 5: the client must drop the withdrawn prompt and must not
    // answer it. The decoder is the thing that saw the withdrawal, so it is
    // the thing that knows.
    let mut decoder = StreamDecoder::new(None);
    decoder.push(
        r#"{"type":"control_request","request_id":"r1",
            "request":{"subtype":"can_use_tool","tool_name":"Write",
                       "input":{},"tool_use_id":"toolu_1"}}"#,
    );
    assert!(decoder.is_open("r1"), "the request is waiting");

    decoder.push(r#"{"type":"control_cancel_request","request_id":"r1"}"#);
    assert!(
        !decoder.is_open("r1"),
        "a withdrawn request must not be answered late"
    );
}

#[test]
fn a_tool_result_closes_the_request_that_gated_it() {
    let mut decoder = StreamDecoder::new(None);
    decoder.push(
        r#"{"type":"control_request","request_id":"r1",
            "request":{"subtype":"can_use_tool","tool_name":"Write",
                       "input":{},"tool_use_id":"toolu_1"}}"#,
    );
    decoder.push(
        r#"{"type":"user","message":{"role":"user","content":[
            {"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}"#,
    );
    assert!(
        !decoder.is_open("r1"),
        "the tool ran, so whatever gated it was answered"
    );
}

#[test]
fn an_allow_response_omits_updated_input_when_the_user_edited_nothing() {
    // The bundle resolves it as ("updatedInput" in e ? e.updatedInput :
    // void 0) ?? original, so a null would work by accident rather than by
    // contract.
    let reply = permission_response("r1", PermissionDecision::Allow, None, None);
    assert_eq!(reply["response"]["response"]["behavior"], json!("allow"));
    assert_eq!(
        reply["response"]["response"].get("updatedInput"),
        None,
        "omitted, not null"
    );
}

#[test]
fn an_allow_response_carries_edited_arguments_when_there_are_any() {
    let edited = json!({"file_path": "/tmp/safer.txt", "content": "x"});
    let reply = permission_response("r1", PermissionDecision::Allow, Some(edited.clone()), None);
    assert_eq!(reply["response"]["response"]["updatedInput"], edited);
}

#[test]
fn a_deny_response_is_still_a_success_control_response() {
    // Denial is not a protocol failure. behavior carries the verdict, and
    // the CLI turns the message into an error tool_result verbatim.
    let reply = permission_response(
        "r1",
        PermissionDecision::Deny,
        None,
        Some("not in this directory".to_owned()),
    );
    assert_eq!(reply["response"]["subtype"], json!("success"));
    assert_eq!(reply["response"]["response"]["behavior"], json!("deny"));
    assert_eq!(
        reply["response"]["response"]["message"],
        json!("not in this directory")
    );
    assert_eq!(
        reply["response"]["response"]["interrupt"],
        json!(false),
        "a denial refuses the tool, it does not abort the turn"
    );
}

#[test]
fn a_denial_with_no_message_still_says_something() {
    let reply = permission_response("r1", PermissionDecision::Deny, None, None);
    let message = reply["response"]["response"]["message"]
        .as_str()
        .expect("a denial always carries a message");
    assert!(!message.is_empty(), "the model is told why");
}

#[test]
fn a_settled_text_block_is_scanned_for_fenced_code() {
    let mut decoder = StreamDecoder::new(None);
    for line in [
        r#"{"type":"stream_event","event":{"type":"content_block_start","index":0,
            "content_block":{"type":"text","text":""}}}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,
            "delta":{"type":"text_delta","text":"here:\n\n```rust\nfn a"}}}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,
            "delta":{"type":"text_delta","text":"() {}\n```\n"}}}"#,
    ] {
        decoder.push(&line.replace('\n', ""));
    }
    let produced =
        decoder.push(r#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#);
    let [EventBody::CodeBlock {
        language,
        source,
        html,
        block,
        ..
    }] = produced.events.as_slice()
    else {
        panic!("expected one code block, got {:?}", produced.events);
    };
    assert_eq!(*block, 0, "the code block keeps its stream index");
    assert_eq!(language.as_deref(), Some("rust"));
    assert_eq!(source, "fn a() {}\n", "a fence split across two deltas");
    assert!(
        html.as_deref()
            .is_some_and(|html| html.starts_with("<pre class=\"code\">")),
        "phase 2 fills html in rather than leaving it null"
    );
}

#[test]
fn an_exit_plan_mode_call_produces_a_plan() {
    let mut decoder = StreamDecoder::new(None);
    let produced = decoder.push(
        r#"{"type":"assistant","message":{"role":"assistant","content":[
            {"type":"tool_use","id":"toolu_9","name":"ExitPlanMode",
             "input":{"plan":"1. read\n2. write"}}]}}"#,
    );
    let names = names(&produced.events);
    assert_eq!(names, vec!["tool_call", "plan"]);
    let EventBody::Plan {
        markdown, state, ..
    } = &produced.events[1]
    else {
        panic!("expected a plan");
    };
    assert_eq!(markdown, "1. read\n2. write");
    assert_eq!(*state, ask_daemon::proto::PlanState::Proposed);
}

#[test]
fn the_cli_denying_a_tool_itself_is_reported_rather_than_swallowed() {
    // system/permission_denied only happens when --permission-prompt-tool
    // did not take effect, which is the failure Task 0 measured. Silently
    // dropping it would look like the model refusing.
    let mut decoder = StreamDecoder::new(None);
    let produced =
        decoder.push(r#"{"type":"system","subtype":"permission_denied","tool_name":"Write"}"#);
    let [EventBody::Error { kind, message, .. }] = produced.events.as_slice() else {
        panic!("expected one error, got {:?}", produced.events);
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert!(
        message.contains("--permission-prompt-tool"),
        "the message names the cause: {message}"
    );
}
