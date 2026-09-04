//! Replays a recorded chat-completions SSE body through the OpenAI-compatible
//! decoder.
//!
//! No network. The fixture is hand-written but realistic and covers the three
//! things section 3 calls out about this family: usage arrives only because
//! the request asked for it, `cost_usd` is always null, and
//! `reasoning_content` is an extension most servers do not implement.
//!
//! The fiddly part is the tool-call assembly. Fragments arrive per `index`
//! across chunks, the id comes on the first fragment and the name can itself
//! be split, so the fixture deliberately splits `searxng__web_search` across
//! two chunks.

use ask_daemon::backend::openai::OpenAiDecoder;
use ask_daemon::backend::provider::ChunkDecoder;
use ask_daemon::proto::{ErrorKind, EventBody, StopReason};

/// A recorded answer with reasoning, prose, a fence and a split tool call.
const STREAM: &str = include_str!("fixtures/openai-sse.txt");

/// Feed the fixture through the decoder in one chunk and flush it.
fn decode(fixture: &str) -> (OpenAiDecoder, Vec<EventBody>) {
    let mut decoder = OpenAiDecoder::default();
    let mut events = decoder.push(fixture);
    events.extend(decoder.finish());
    (decoder, events)
}

/// The `event` tag of each body.
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
fn a_recorded_answer_produces_the_events_in_order() {
    let (_, events) = decode(STREAM);
    assert_eq!(
        names(&events),
        vec![
            "thinking_delta",
            "text_delta",
            "text_delta",
            "text_delta",
            "usage",
            "code_block",
        ],
        "the keepalive, the role-only chunk and [DONE] carry no event"
    );
}

#[test]
fn a_role_only_first_chunk_produces_no_delta() {
    // Every server in this family opens with {"role":"assistant","content":""}
    // and emitting that would put an empty delta through the store on every
    // single turn.
    let (_, events) = decode(STREAM);
    assert!(
        !events
            .iter()
            .any(|body| matches!(body, EventBody::TextDelta { text, .. } if text.is_empty())),
        "an empty content field is not a delta"
    );
}

#[test]
fn reasoning_content_becomes_a_thinking_delta_when_a_server_sends_it() {
    // An extension most servers do not implement, which is why the pane must
    // treat a turn with no thinking at all as normal.
    let (_, events) = decode(STREAM);
    let thinking: Vec<&str> = events
        .iter()
        .filter_map(|body| match body {
            EventBody::ThinkingDelta { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(thinking, vec!["Short answer wanted."]);
}

#[test]
fn a_server_that_sends_no_reasoning_produces_no_thinking() {
    let mut decoder = OpenAiDecoder::default();
    let events = decoder.push(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\n\n",
    );
    assert_eq!(names(&events), vec!["text_delta"]);
}

#[test]
fn the_tool_call_assembles_out_of_fragments_keyed_by_index() {
    // The id arrives on the first fragment only, the name is split across
    // two, and the arguments across two more. Keying by id rather than by
    // index would lose everything after the first fragment.
    let (mut decoder, _) = decode(STREAM);
    let calls = decoder.take_tool_calls();
    assert_eq!(calls.len(), 1, "{calls:?}");
    assert_eq!(
        calls[0].id, "call_abc",
        "the id comes on the first fragment"
    );
    assert_eq!(
        calls[0].name, "searxng__web_search",
        "a name split across two chunks is one name"
    );
    assert_eq!(calls[0].arguments, "{\"query\":\"unix socket\"}");
    assert_eq!(
        calls[0].input(),
        serde_json::json!({"query": "unix socket"})
    );
}

#[test]
fn two_tool_calls_stay_apart() {
    let mut decoder = OpenAiDecoder::default();
    decoder.push(concat!(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[",
        "{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"one\",\"arguments\":\"{}\"}},",
        "{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"two\",\"arguments\":\"{}\"}}",
        "]}}]}\n\n"
    ));
    let mut calls = decoder.take_tool_calls();
    calls.sort_by(|left, right| left.id.cmp(&right.id));
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].name, "one");
    assert_eq!(calls[1].name, "two");
}

#[test]
fn a_finish_reason_of_tool_calls_stops_on_tool_use() {
    let (decoder, _) = decode(STREAM);
    assert_eq!(decoder.stop(), StopReason::ToolUse);
}

#[test]
fn usage_arrives_only_because_the_request_asked_for_it() {
    // Section 3: a streamed completion sends no counts unless the request
    // sets stream_options.include_usage, which this adapter always does. A
    // server that ignores the option sends no usage chunk and the turn
    // carries no usage event, which is the honest outcome.
    let (_, events) = decode(STREAM);
    let usage = events
        .iter()
        .find(|body| matches!(body, EventBody::Usage { .. }))
        .expect("the final chunk carried counts");
    let EventBody::Usage {
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        thinking_tokens,
        cost_usd,
        rate_limit,
        ..
    } = usage
    else {
        unreachable!("filtered to Usage");
    };
    assert_eq!(*input_tokens, 41);
    assert_eq!(*output_tokens, 63);
    assert_eq!(*thinking_tokens, Some(12));
    assert_eq!(*cache_read_tokens, None, "no cache split in this family");
    assert_eq!(*cache_write_tokens, None);
    assert_eq!(
        *cost_usd, None,
        "the base url alone does not say who is serving, so there is no price to look up"
    );
    assert_eq!(*rate_limit, None);
}

#[test]
fn a_server_that_ignores_include_usage_produces_no_usage_event() {
    let mut decoder = OpenAiDecoder::default();
    let events = decoder.push(concat!(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n"
    ));
    assert_eq!(names(&events), vec!["text_delta"]);
    assert_eq!(decoder.stop(), StopReason::EndTurn);
}

#[test]
fn the_settled_prose_is_scanned_for_fenced_code() {
    let (_, events) = decode(STREAM);
    let [EventBody::CodeBlock {
        language,
        source,
        html,
        ..
    }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::CodeBlock { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one code block: {:?}", names(&events));
    };
    assert_eq!(language.as_deref(), Some("rust"));
    assert_eq!(source, "UnixListener::bind(p)?\n");
    assert!(html.as_deref().is_some_and(|html| html.contains("<pre")));
}

#[test]
fn a_stream_split_mid_frame_decodes_the_same() {
    let (_, whole) = decode(STREAM);

    let mut decoder = OpenAiDecoder::default();
    let mut piecemeal = Vec::new();
    for chunk in STREAM.as_bytes().chunks(11) {
        piecemeal.extend(decoder.push(std::str::from_utf8(chunk).expect("ascii fixture")));
    }
    piecemeal.extend(decoder.finish());
    assert_eq!(piecemeal, whole, "framing must not change what is produced");
}

#[test]
fn a_crlf_stream_decodes_the_same() {
    let (_, lf) = decode(STREAM);
    let (_, crlf) = decode(&STREAM.replace('\n', "\r\n"));
    assert_eq!(crlf, lf);
}

#[test]
fn the_done_sentinel_is_not_treated_as_json() {
    let mut decoder = OpenAiDecoder::default();
    assert!(
        decoder.push("data: [DONE]\n\n").is_empty(),
        "[DONE] ends the stream, it is not a payload"
    );
}

#[test]
fn a_keepalive_comment_produces_nothing() {
    let mut decoder = OpenAiDecoder::default();
    assert!(decoder.push(": keepalive\n\n").is_empty());
}

#[test]
fn an_error_body_becomes_an_event_and_stops_the_turn() {
    let mut decoder = OpenAiDecoder::default();
    let events = decoder.push(
        "data: {\"error\":{\"message\":\"model not found\",\"type\":\"invalid_request_error\"}}\n\n",
    );
    let [EventBody::Error { kind, message, .. }] = events.as_slice() else {
        panic!("expected one error, got {events:?}");
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert_eq!(message, "model not found");
    assert_eq!(decoder.stop(), StopReason::Error);
}

#[test]
fn a_data_frame_that_is_not_json_becomes_an_event_rather_than_a_silent_drop() {
    let mut decoder = OpenAiDecoder::default();
    let events = decoder.push("data: <html>502 Bad Gateway</html>\n\n");
    assert!(matches!(
        events.as_slice(),
        [EventBody::Error {
            kind: ErrorKind::Protocol,
            ..
        }]
    ));
}

#[test]
fn a_length_finish_reports_max_tokens() {
    let mut decoder = OpenAiDecoder::default();
    decoder
        .push("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n");
    assert_eq!(decoder.stop(), StopReason::MaxTokens);
}

#[test]
fn a_content_filter_finish_is_an_error_rather_than_a_clean_end() {
    let mut decoder = OpenAiDecoder::default();
    decoder.push(
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n",
    );
    assert_eq!(decoder.stop(), StopReason::Error);
}

#[test]
fn no_event_carries_a_turn_the_backend_invented() {
    let (_, events) = decode(STREAM);
    for body in events {
        let value = serde_json::to_value(&body).expect("a body serializes");
        if let Some(turn) = value.get("turn") {
            assert!(turn.is_null(), "an adapter must not mint a turn: {value}");
        }
    }
}
