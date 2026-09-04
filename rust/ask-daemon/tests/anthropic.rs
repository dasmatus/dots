//! Replays a recorded `/v1/messages` SSE body through the Anthropic decoder.
//!
//! No network. The decoder holds no I/O and the fixture is hand-written but
//! realistic, following the shapes section 1 recorded one layer up: the same
//! `content_block_start` / `content_block_delta` / `content_block_stop`
//! structure the harness wraps.
//!
//! Two things differ from the harness and both are asserted here. Thinking
//! carries real text rather than an empty string, and the tool arguments
//! stream as `input_json_delta` fragments that only parse once the last one
//! lands.

use ask_daemon::backend::anthropic::{cost_usd, models, AnthropicDecoder};
use ask_daemon::backend::provider::ChunkDecoder;
use ask_daemon::proto::{ErrorKind, EventBody, StopReason};

/// A recorded answer with thinking, prose, a fence and a tool call.
const STREAM: &str = include_str!("fixtures/anthropic-sse.txt");

/// Feed the fixture through the decoder in one chunk and flush it.
fn decode(fixture: &str) -> (AnthropicDecoder, Vec<EventBody>) {
    let mut decoder = AnthropicDecoder::default();
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
            "thinking_delta",
            "text_delta",
            "text_delta",
            "text_delta",
            "usage",
            "code_block",
        ],
        "signature_delta, content_block_stop and message_stop carry no event"
    );
}

#[test]
fn thinking_carries_real_text_here_unlike_the_harness() {
    let (_, events) = decode(STREAM);
    let thinking: Vec<(&str, u32)> = events
        .iter()
        .filter_map(|body| match body {
            EventBody::ThinkingDelta { text, block, .. } => Some((text.as_str(), *block)),
            _ => None,
        })
        .collect();
    assert_eq!(
        thinking,
        vec![("They want the bind call. ", 0), ("One line is enough.", 0)],
        "real text, and the block index the stream gave it"
    );
}

#[test]
fn the_prose_keeps_the_block_index_the_stream_used() {
    // The harness and this API both number content blocks, and the pane
    // groups by that number, so a decoder that flattened everything to zero
    // would merge a thinking block into the prose after it.
    let (_, events) = decode(STREAM);
    let blocks: Vec<u32> = events
        .iter()
        .filter_map(|body| match body {
            EventBody::TextDelta { block, .. } => Some(*block),
            _ => None,
        })
        .collect();
    assert_eq!(blocks, vec![1, 1, 1], "the text block is index 1, not 0");
}

#[test]
fn the_tool_arguments_assemble_out_of_their_fragments() {
    // The block opens with an empty input and the arguments arrive as
    // input_json_delta fragments that only parse once the last one lands.
    let (mut decoder, _) = decode(STREAM);
    let calls = decoder.take_tool_calls();
    assert_eq!(calls.len(), 1, "{calls:?}");
    assert_eq!(calls[0].id, "toolu_01Xyz");
    assert_eq!(calls[0].name, "searxng__web_search");
    assert_eq!(
        calls[0].arguments, "{\"query\":\"unix socket rust\"}",
        "two fragments, one object"
    );
    assert_eq!(
        calls[0].input(),
        serde_json::json!({"query": "unix socket rust"})
    );
}

#[test]
fn a_turn_that_asked_for_a_tool_stops_on_tool_use() {
    let (decoder, _) = decode(STREAM);
    assert_eq!(decoder.stop(), StopReason::ToolUse);
}

#[test]
fn usage_takes_its_input_counts_from_message_start() {
    // Only message_start carries the input counts and only message_delta
    // carries the output count, so a decoder that read one line gets half a
    // usage event.
    let (_, events) = decode(STREAM);
    let usage = events
        .iter()
        .find(|body| matches!(body, EventBody::Usage { .. }))
        .expect("message_delta produced a usage event");
    let EventBody::Usage {
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        cost_usd,
        rate_limit,
        ..
    } = usage
    else {
        unreachable!("filtered to Usage");
    };
    assert_eq!(*input_tokens, 24, "off message_start");
    assert_eq!(*output_tokens, 97, "off message_delta");
    assert_eq!(*cache_read_tokens, Some(4096));
    assert_eq!(*cache_write_tokens, Some(118));
    assert!(
        cost_usd.is_some(),
        "the model is in the price table, so the daemon can price the turn"
    );
    assert_eq!(
        *rate_limit, None,
        "section 3 gives the rate limit column to claude-code alone"
    );
}

#[test]
fn a_dated_snapshot_is_priced_by_the_alias_it_belongs_to() {
    // The value the daemon prices against is message_start.message.model.
    // Several models carry a dated snapshot id alongside their alias, and
    // that field can hold either form, so an exact lookup priced nothing on
    // the turns that returned the dated one. The fixture used to hand-write
    // an alias, which is the only reason that looked fine.
    assert!(
        cost_usd(Some("claude-haiku-4-5-20251001"), 1_000_000, 0).is_some(),
        "a dated snapshot has to price as the alias it resolves from"
    );
    assert_eq!(
        cost_usd(Some("claude-haiku-4-5-20251001"), 1_000_000, 1_000_000),
        cost_usd(Some("claude-haiku-4-5"), 1_000_000, 1_000_000),
        "and price identically to it"
    );
}

#[test]
fn a_point_release_prices_as_the_line_it_belongs_to() {
    // Nothing in the table collides today, so this is the forward-looking
    // half: a future `claude-opus-5-1` starts with `claude-opus-5`, and the
    // longest-match rule is what keeps billing right on the day one ships,
    // whether the table has gained a row for it or not.
    let point_release = cost_usd(Some("claude-opus-5-1-20260401"), 1_000_000, 0)
        .expect("an unknown point release still prices as its line");
    let line = cost_usd(Some("claude-opus-5"), 1_000_000, 0).expect("so does the line itself");
    assert!(
        (point_release - line).abs() < 1e-9,
        "the longest matching alias wins: {point_release} against {line}"
    );
}

#[test]
fn a_known_model_is_priced_and_an_unknown_one_is_not() {
    // The API reports tokens and never a price, so the table is the only
    // source. A wrong number on a cost display is worse than no number.
    let priced = cost_usd(Some("claude-opus-5"), 1_000_000, 1_000_000)
        .expect("a model in the table is priced");
    assert!(
        (priced - 30.0).abs() < 1e-9,
        "a million of each at 5 and 25 dollars: {priced}"
    );
    assert_eq!(
        cost_usd(Some("gpt-nothing-anthropic-ever-shipped"), 10, 10),
        None,
        "a model outside the line is null rather than a guess"
    );
    assert_eq!(cost_usd(None, 10, 10), None);
}

#[test]
fn every_model_the_pane_offers_can_be_priced() {
    // The pane's list and the price table are two hand-maintained lists of
    // the same ids. Adding a model to one and not the other shows up as a
    // silently null cost, so the suite checks they agree.
    for model in models() {
        assert!(
            cost_usd(Some(model), 1_000, 1_000).is_some(),
            "the pane offers {model} but the price table has no row for it"
        );
    }
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
    // SSE frames span several lines and a chunk off the wire respects
    // neither the line nor the frame boundary.
    let (_, whole) = decode(STREAM);

    let mut decoder = AnthropicDecoder::default();
    let mut piecemeal = Vec::new();
    for chunk in STREAM.as_bytes().chunks(7) {
        piecemeal.extend(decoder.push(std::str::from_utf8(chunk).expect("ascii fixture")));
    }
    piecemeal.extend(decoder.finish());
    assert_eq!(piecemeal, whole, "framing must not change what is produced");
}

#[test]
fn a_crlf_stream_decodes_the_same() {
    // SSE is specified with CRLF and servers disagree about whether to send
    // it, so the line splitter has to take both.
    let (_, lf) = decode(STREAM);
    let (_, crlf) = decode(&STREAM.replace('\n', "\r\n"));
    assert_eq!(crlf, lf);
}

#[test]
fn a_keepalive_comment_produces_nothing() {
    let mut decoder = AnthropicDecoder::default();
    assert!(decoder.push(": ping\n\n").is_empty());
}

#[test]
fn an_error_frame_becomes_an_event_and_stops_the_turn() {
    let mut decoder = AnthropicDecoder::default();
    let events = decoder.push(
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
    );
    let [EventBody::Error { kind, message, .. }] = events.as_slice() else {
        panic!("expected one error, got {events:?}");
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert_eq!(message, "Overloaded");
    assert_eq!(decoder.stop(), StopReason::Error);
}

#[test]
fn a_data_frame_that_is_not_json_becomes_an_event_rather_than_a_silent_drop() {
    let mut decoder = AnthropicDecoder::default();
    let events = decoder.push("data: <html>502</html>\n\n");
    assert!(matches!(
        events.as_slice(),
        [EventBody::Error {
            kind: ErrorKind::Protocol,
            ..
        }]
    ));
}

#[test]
fn a_max_tokens_stop_reports_max_tokens() {
    let mut decoder = AnthropicDecoder::default();
    decoder.push(
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":8}}\n\n",
    );
    assert_eq!(decoder.stop(), StopReason::MaxTokens);
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
