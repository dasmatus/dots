//! Pins the `Backend` trait's shape, the registry, and the two framing
//! helpers every provider adapter is built on.
//!
//! The trait test is the one worth reading. `codex.rs` exists to prove the
//! trait fits a backend nobody has written, and
//! `a_backend_with_nothing_behind_it_still_satisfies_the_trait` is that claim
//! stated as code: a backend with no process, no credential, no transport and
//! no decoder still compiles, still lists itself honestly, and still refuses
//! to start.
//!
//! The framing helpers are here rather than in one adapter's file because all
//! three providers share them, and a bug in either would look like a
//! different bug in three places.

use std::sync::Arc;

use tokio::sync::mpsc;
use uuid::Uuid;

use ask_daemon::backend::codex::CodexBackend;
use ask_daemon::backend::{
    unconfigured_registry, Backend, BackendCommand, BackendMessage, LineBuffer, SseDecoder,
    SseFrame, ANTHROPIC, CLAUDE_CODE, CODEX, OLLAMA, OPENAI,
};
use ask_daemon::proto::{BackendState, ErrorKind, EventBody, PermissionDecision, PermissionScope};
use ask_daemon::secrets::SecretStore;

#[test]
fn the_registry_lists_every_backend_the_spec_names() {
    let registry = unconfigured_registry();
    let ids: Vec<String> = registry
        .info()
        .into_iter()
        .map(|backend| backend.id)
        .collect();
    assert_eq!(
        ids,
        vec![
            CLAUDE_CODE.to_owned(),
            ANTHROPIC.to_owned(),
            OPENAI.to_owned(),
            OLLAMA.to_owned(),
            CODEX.to_owned(),
        ],
        "the ids and the display order both come from section 3"
    );
    for id in &ids {
        assert!(registry.contains(id), "{id} must resolve");
    }
    assert!(
        !registry.contains("gpt-5-turbo-max"),
        "an id nobody registered must not resolve"
    );
}

#[test]
fn an_unavailable_backend_says_why() {
    // The spec makes `detail` null only when state is ready, so a backend
    // that cannot run has to explain itself or the pane shows a greyed row
    // with no reason on it.
    for backend in unconfigured_registry().info() {
        assert_ne!(backend.state, BackendState::Ready);
        assert!(
            backend.detail.is_some_and(|detail| !detail.is_empty()),
            "a backend that is not ready must say why"
        );
        assert!(
            backend.models.is_empty(),
            "and must not offer models it cannot run"
        );
    }
}

#[test]
fn starting_a_backend_that_is_not_configured_fails_rather_than_panicking() {
    let registry = unconfigured_registry();
    let (events, _produced) = mpsc::unbounded_channel();
    let failed = registry
        .start(
            CLAUDE_CODE,
            Uuid::new_v4(),
            None,
            std::path::Path::new("/tmp"),
            std::path::PathBuf::from("/tmp"),
            events,
        )
        .expect_err("an unconfigured backend cannot start");
    assert!(failed.contains(CLAUDE_CODE), "{failed}");
}

#[test]
fn starting_a_backend_that_does_not_exist_names_the_id() {
    let registry = unconfigured_registry();
    let (events, _produced) = mpsc::unbounded_channel();
    let failed = registry
        .start(
            "nothing-like-this",
            Uuid::new_v4(),
            None,
            std::path::Path::new("/tmp"),
            std::path::PathBuf::from("/tmp"),
            events,
        )
        .expect_err("an unknown id cannot start");
    assert!(failed.contains("nothing-like-this"), "{failed}");
}

#[test]
fn a_backend_with_nothing_behind_it_still_satisfies_the_trait() {
    // codex is the shape check. No process, no credential, no transport, no
    // decoder, and it still compiles as a Backend, lists itself honestly and
    // refuses to start. The day somebody records a codex session, this is
    // the only file that has to change.
    let codex = CodexBackend;
    assert_eq!(codex.id(), CODEX);

    let info = codex.info(&SecretStore::default());
    assert_eq!(info.id, CODEX);
    assert_eq!(info.state, BackendState::Unconfigured);
    let detail = info.detail.expect("an unconfigured backend says why");
    assert!(
        detail.contains("recorded"),
        "and says what filling it in would take: {detail}"
    );

    assert!(
        !codex.produces_diffs_and_plans(),
        "the default is false, which is what every raw provider needs"
    );
}

#[tokio::test]
async fn an_event_sink_carries_the_conversation_that_produced_it() {
    // One channel is shared by every running backend, so the thread has to
    // travel with the body rather than with the channel.
    let registry = unconfigured_registry();
    drop(registry);

    let conversation = Uuid::new_v4();
    let (events, mut produced) = mpsc::unbounded_channel();
    let sink = ask_daemon::backend::EventSink::new(conversation, events);
    assert_eq!(sink.conversation(), conversation);

    assert!(sink.emit(EventBody::TextDelta {
        turn: None,
        block: 0,
        text: "hello".to_owned(),
    }));
    let BackendMessage {
        conversation: seen,
        body,
    } = produced.recv().await.expect("the event arrives");
    assert_eq!(seen, conversation);
    assert!(matches!(body, EventBody::TextDelta { .. }));
}

#[tokio::test]
async fn a_sink_whose_pump_is_gone_reports_it_rather_than_failing() {
    let (events, produced) = mpsc::unbounded_channel();
    let sink = ask_daemon::backend::EventSink::new(Uuid::new_v4(), events);
    drop(produced);
    assert!(
        !sink.fail(ErrorKind::Protocol, "nobody is listening".to_owned(), false),
        "a backend uses this to stop reading its transport, not to raise an error nobody sees"
    );
}

#[tokio::test]
async fn a_command_reaches_the_backend_without_awaiting() {
    // The reason BackendHandle::send is synchronous: Hub::dispatch calls it
    // from inside the lock, and an await there would not compile.
    let (commands, mut inbox) = mpsc::unbounded_channel();
    let handle = ask_daemon::backend::BackendHandle::new(commands);
    assert!(handle.send(BackendCommand::Permission {
        request: "r1".to_owned(),
        decision: PermissionDecision::Allow,
        scope: PermissionScope::Forever,
        updated_input: None,
        message: None,
    }));

    let BackendCommand::Permission {
        request,
        decision,
        scope,
        ..
    } = inbox.recv().await.expect("the command arrives")
    else {
        panic!("the wrong command arrived");
    };
    assert_eq!(request, "r1");
    assert_eq!(decision, PermissionDecision::Allow);
    assert_eq!(
        scope,
        PermissionScope::Forever,
        "the scope has to reach the backend or policy.rs can never write a forever rule"
    );
}

#[test]
fn a_handle_whose_backend_ended_reports_it() {
    let (commands, inbox) = mpsc::unbounded_channel();
    let handle = ask_daemon::backend::BackendHandle::new(commands);
    drop(inbox);
    assert!(!handle.send(BackendCommand::Interrupt));
}

#[test]
fn the_line_buffer_keeps_the_incomplete_tail() {
    // A chunk off the wire respects no line boundary, so a buffer that
    // returned a partial line would hand a decoder half an object.
    let mut buffer = LineBuffer::default();
    assert!(buffer.push("{\"a\":").is_empty(), "half a line is no line");
    assert_eq!(
        buffer.push("1}\n{\"b\":2}\n"),
        vec!["{\"a\":1}", "{\"b\":2}"]
    );
    assert_eq!(buffer.finish(), None, "nothing was left over");
}

#[test]
fn the_line_buffer_strips_crlf() {
    let mut buffer = LineBuffer::default();
    assert_eq!(buffer.push("one\r\ntwo\r\n"), vec!["one", "two"]);
}

#[test]
fn the_line_buffer_returns_a_last_line_with_no_newline() {
    // A server that ends without a final newline still sent a whole message.
    let mut buffer = LineBuffer::default();
    assert_eq!(buffer.push("done\nlast"), vec!["done"]);
    assert_eq!(buffer.finish(), Some("last".to_owned()));
    assert_eq!(buffer.finish(), None, "and it is not returned twice");
}

#[test]
fn an_empty_line_is_a_line() {
    // SSE ends a frame with one, so swallowing it would merge every frame in
    // the stream into one.
    let mut buffer = LineBuffer::default();
    assert_eq!(buffer.push("data: x\n\n"), vec!["data: x", ""]);
}

#[test]
fn an_sse_frame_closes_on_a_blank_line() {
    let mut decoder = SseDecoder::default();
    assert_eq!(decoder.push("event: message_start"), None);
    assert_eq!(decoder.push("data: {\"type\":\"x\"}"), None);
    assert_eq!(
        decoder.push(""),
        Some(SseFrame {
            name: "message_start".to_owned(),
            data: "{\"type\":\"x\"}".to_owned(),
        })
    );
}

#[test]
fn several_data_lines_join_with_newlines() {
    // What the SSE specification requires, and what a server sending a
    // pretty-printed payload produces.
    let mut decoder = SseDecoder::default();
    decoder.push("data: {");
    decoder.push("data:   \"a\": 1");
    decoder.push("data: }");
    assert_eq!(
        decoder
            .push("")
            .expect("the blank line closed the frame")
            .data,
        "{\n  \"a\": 1\n}"
    );
}

#[test]
fn a_comment_line_produces_nothing() {
    let mut decoder = SseDecoder::default();
    assert_eq!(decoder.push(": keepalive"), None);
    assert_eq!(decoder.push(""), None, "a keepalive closes no frame");
}

#[test]
fn a_field_the_daemon_has_no_use_for_is_dropped() {
    // id and retry are in the specification and neither provider sends
    // anything the daemon would do with them.
    let mut decoder = SseDecoder::default();
    decoder.push("id: 42");
    decoder.push("retry: 3000");
    decoder.push("data: x");
    let frame = decoder.push("").expect("the frame closed");
    assert_eq!(frame.data, "x");
    assert!(frame.name.is_empty(), "this frame named no event");
}

#[test]
fn a_data_line_with_no_leading_space_still_decodes() {
    // The specification strips one optional leading space and servers
    // disagree about sending it.
    let mut decoder = SseDecoder::default();
    decoder.push("data:tight");
    assert_eq!(decoder.push("").expect("the frame closed").data, "tight");
}

#[test]
fn a_registry_hands_every_backend_the_same_policy() {
    // A forever rule written by one thread has to be the rule the next one
    // reads, so there is one store rather than one per backend.
    let registry = unconfigured_registry();
    let first = registry.policy();
    let second = registry.policy();
    assert!(
        Arc::ptr_eq(&first, &second),
        "two calls must hand back the same store"
    );
}
