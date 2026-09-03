//! Replays a recorded `/api/chat` NDJSON body through the ollama decoder.
//!
//! No server is started and nothing connects to 11434. The decoder holds no
//! I/O, so a fixture goes straight into it, which is what lets this run in
//! the nix sandbox where 11434 is not there.
//!
//! The fixture was written by hand against a real `ornith:9b` stream rather
//! than captured, so it is realistic rather than authoritative. What it is
//! authoritative about is what the decoder must produce from those bytes.
//!
//! Chunk boundaries are the second thing under test. A byte stream respects
//! no line boundary, so the decoder is fed one byte at a time in
//! `a_stream_split_mid_line_decodes_the_same`, which is the shape that
//! breaks a decoder that assumes each chunk is a whole line.

use ask_daemon::backend::ollama::{available_memory, choose_model, InstalledModel, OllamaDecoder};
use ask_daemon::backend::provider::ChunkDecoder;
use ask_daemon::proto::{ErrorKind, EventBody, StopReason};

/// A recorded answer with thinking, prose and a fenced block.
const PROSE: &str = include_str!("fixtures/ollama-ndjson.txt");

/// A recorded answer that asks for a tool.
const TOOLS: &str = include_str!("fixtures/ollama-tools-ndjson.txt");

/// Feed a fixture through the decoder in one chunk and flush it.
fn decode(fixture: &str) -> (OllamaDecoder, Vec<EventBody>) {
    let mut decoder = OllamaDecoder::default();
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
    let (_, events) = decode(PROSE);
    assert_eq!(
        names(&events),
        vec![
            "thinking_delta",
            "thinking_delta",
            "text_delta",
            "text_delta",
            "text_delta",
            "text_delta",
            "text_delta",
            "usage",
            "code_block",
        ],
        "thinking, then prose, then the counts, then the settled fence"
    );
}

#[test]
fn the_prose_arrives_whole_across_the_deltas() {
    let (mut decoder, _) = decode(PROSE);
    assert_eq!(
        decoder.take_text(),
        "A unix socket:\n\n```rust\nlet s = UnixListener::bind(p)?;\n```\n"
    );
}

#[test]
fn thinking_arrives_as_real_text_on_a_model_that_separates_it() {
    // Unlike the harness, where thinking is always empty. Section 3 says the
    // pane must treat both as normal.
    let (_, events) = decode(PROSE);
    let thinking: Vec<&str> = events
        .iter()
        .filter_map(|body| match body {
            EventBody::ThinkingDelta { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        thinking,
        vec!["The user wants a short answer. ", "Keep it to one line."]
    );
}

#[test]
fn an_empty_content_field_produces_no_delta() {
    // Every chunk carries `content`, and the first and last carry an empty
    // one. Emitting those would put empty deltas through the store for every
    // turn.
    let (_, events) = decode(PROSE);
    assert!(
        !events
            .iter()
            .any(|body| matches!(body, EventBody::TextDelta { text, .. } if text.is_empty())),
        "an empty content field is not a delta"
    );
}

#[test]
fn the_final_chunk_carries_the_counts_and_nothing_else() {
    // Section 3: ollama reports prompt_eval_count and eval_count and nothing
    // else, so cost and the cache split are null on every ollama turn. A
    // usage panel that assumes a number shows zeros for a local model, and
    // that is the server's honest answer.
    let (_, events) = decode(PROSE);
    let usage = events
        .iter()
        .find(|body| matches!(body, EventBody::Usage { .. }))
        .expect("the done chunk produced a usage event");
    let EventBody::Usage {
        input_tokens,
        output_tokens,
        cache_read_tokens,
        cache_write_tokens,
        thinking_tokens,
        cost_usd,
        rate_limit,
        turn,
    } = usage
    else {
        unreachable!("filtered to Usage");
    };
    assert_eq!(*input_tokens, 31);
    assert_eq!(*output_tokens, 48);
    assert_eq!(*cache_read_tokens, None, "ollama has no cache accounting");
    assert_eq!(*cache_write_tokens, None);
    assert_eq!(*thinking_tokens, None);
    assert_eq!(*cost_usd, None, "a local model has no price");
    assert_eq!(*rate_limit, None, "and reports no limit in the stream");
    assert_eq!(*turn, None, "the adapter does not mint a turn");
}

#[test]
fn a_finished_stream_ends_the_turn_normally() {
    let (decoder, _) = decode(PROSE);
    assert_eq!(decoder.stop(), StopReason::EndTurn);
}

#[test]
fn the_settled_prose_is_scanned_for_fenced_code() {
    let (_, events) = decode(PROSE);
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
    assert_eq!(source, "let s = UnixListener::bind(p)?;\n");
    assert!(
        html.as_deref()
            .is_some_and(|html| html.contains("<span style=\"color:#")),
        "the daemon highlights so the pane does not"
    );
}

#[test]
fn a_stream_split_mid_line_decodes_the_same() {
    // A chunk off the wire respects no line boundary, so this feeds the
    // fixture a byte at a time. A decoder that assumed each chunk was a
    // whole line fails here and nowhere else.
    let (_, whole) = decode(PROSE);

    let mut decoder = OllamaDecoder::default();
    let mut piecemeal = Vec::new();
    for byte in PROSE.as_bytes() {
        piecemeal.extend(decoder.push(std::str::from_utf8(&[*byte]).expect("ascii fixture")));
    }
    piecemeal.extend(decoder.finish());

    assert_eq!(names(&piecemeal), names(&whole));
    assert_eq!(piecemeal, whole, "framing must not change what is produced");
}

#[test]
fn a_body_with_no_trailing_newline_still_yields_its_last_line() {
    let trimmed = PROSE.trim_end_matches('\n');
    let mut decoder = OllamaDecoder::default();
    let mut events = decoder.push(trimmed);
    events.extend(decoder.finish());
    assert!(
        events
            .iter()
            .any(|body| matches!(body, EventBody::Usage { .. })),
        "the final chunk must not be lost to a missing newline"
    );
}

#[test]
fn a_tool_call_arrives_whole_rather_than_streamed() {
    // The one place ollama is easier than the two SSE providers.
    let (mut decoder, events) = decode(TOOLS);
    let calls = decoder.take_tool_calls();
    assert_eq!(calls.len(), 1, "{calls:?}");
    assert_eq!(calls[0].name, "searxng__web_search");
    assert_eq!(
        calls[0].input(),
        serde_json::json!({"query": "nixos flake check"}),
        "the arguments parse without assembling fragments"
    );
    assert!(
        !calls[0].id.is_empty(),
        "ollama sends no call id, so the decoder synthesizes one"
    );
    assert_eq!(
        names(&events),
        vec!["usage"],
        "a tool-only answer produces no prose"
    );
}

#[test]
fn a_turn_that_asked_for_a_tool_stops_on_tool_use() {
    let (decoder, _) = decode(TOOLS);
    assert_eq!(
        decoder.stop(),
        StopReason::ToolUse,
        "done_reason says stop, but a pending call is what the turn is waiting on"
    );
}

#[test]
fn a_server_error_becomes_an_event_rather_than_a_panic() {
    let mut decoder = OllamaDecoder::default();
    let events = decoder.push("{\"error\":\"model \\\"nope\\\" not found\"}\n");
    let [EventBody::Error { kind, message, .. }] = events.as_slice() else {
        panic!("expected one error, got {events:?}");
    };
    assert_eq!(*kind, ErrorKind::Protocol);
    assert!(message.contains("not found"), "{message}");
    assert_eq!(decoder.stop(), StopReason::Error);
}

#[test]
fn a_line_that_is_not_json_becomes_an_event_rather_than_a_silent_drop() {
    let mut decoder = OllamaDecoder::default();
    let events = decoder.push("<html>502 Bad Gateway</html>\n");
    assert!(matches!(
        events.as_slice(),
        [EventBody::Error {
            kind: ErrorKind::Protocol,
            ..
        }]
    ));
}

#[test]
fn a_length_stop_reports_max_tokens() {
    let mut decoder = OllamaDecoder::default();
    decoder.push("{\"done\":true,\"done_reason\":\"length\",\"eval_count\":8}\n");
    assert_eq!(decoder.stop(), StopReason::MaxTokens);
}

#[test]
fn no_event_carries_a_turn_the_backend_invented() {
    let (_, events) = decode(PROSE);
    for body in events {
        let value = serde_json::to_value(&body).expect("a body serializes");
        if let Some(turn) = value.get("turn") {
            assert!(turn.is_null(), "an adapter must not mint a turn: {value}");
        }
    }
}

/// One installed model, for the picker tests.
fn installed(name: &str, gigabytes: u64) -> InstalledModel {
    InstalledModel {
        name: name.to_owned(),
        size_bytes: gigabytes * 1024 * 1024 * 1024,
    }
}

#[test]
fn the_default_model_comes_from_what_is_installed() {
    // No tag is hardcoded anywhere in the adapter. A tag written into Rust
    // is stale the day the next model ships, and it names something this
    // machine may never have pulled, so a send would draw a 404 from a
    // server that is running perfectly well.
    let models = vec![
        installed("gemma4:e4b", 9),
        installed("ornith:9b", 5),
        installed("tiny:1b", 1),
    ];
    // 24 GiB available, two thirds of which is about 16, so the 9 GiB model
    // fits and is the best answer.
    assert_eq!(
        choose_model(&models, Some(24 * 1024 * 1024 * 1024)),
        Some("gemma4:e4b"),
        "the biggest that fits wins"
    );
}

#[test]
fn a_tight_machine_gets_a_model_that_fits() {
    let models = vec![
        installed("gemma4:e4b", 9),
        installed("ornith:9b", 5),
        installed("tiny:1b", 1),
    ];
    // 8 GiB available, two thirds of which is 5.28, so the 9 GiB model is
    // out and the 5 GiB one is the best of the rest.
    assert_eq!(
        choose_model(&models, Some(8 * 1024 * 1024 * 1024)),
        Some("ornith:9b"),
        "headroom keeps the 9 GiB model out on an 8 GiB budget"
    );
}

#[test]
fn a_machine_where_nothing_fits_still_gets_an_answer() {
    // Slow beats refusing: ollama pages or falls back to CPU, and the user
    // gets a reply rather than an error about memory they cannot act on.
    let models = vec![installed("gemma4:e4b", 9), installed("ornith:9b", 5)];
    assert_eq!(
        choose_model(&models, Some(1024 * 1024 * 1024)),
        Some("ornith:9b"),
        "the smallest installed model is the fallback"
    );
}

#[test]
fn an_unreadable_meminfo_falls_back_to_the_smallest_model() {
    // What a sandbox with no /proc looks like. Guessing large when the
    // daemon cannot tell how much room it has is the wrong direction.
    let models = vec![installed("gemma4:e4b", 9), installed("ornith:9b", 5)];
    assert_eq!(choose_model(&models, None), Some("ornith:9b"));
}

#[test]
fn a_server_with_no_model_pulled_picks_nothing() {
    assert_eq!(choose_model(&[], Some(64 * 1024 * 1024 * 1024)), None);
    assert_eq!(choose_model(&[], None), None);
}

#[test]
fn the_pick_does_not_depend_on_the_order_api_tags_returned() {
    let ascending = vec![
        installed("tiny:1b", 1),
        installed("ornith:9b", 5),
        installed("gemma4:e4b", 9),
    ];
    let descending: Vec<InstalledModel> = ascending.iter().rev().cloned().collect();
    let budget = Some(24 * 1024 * 1024 * 1024);
    assert_eq!(
        choose_model(&ascending, budget),
        choose_model(&descending, budget)
    );
}

#[test]
fn two_models_of_the_same_size_break_the_tie_by_name() {
    // Otherwise the pick depends on the order the server happened to list
    // them in, and the pane would show a different default from run to run.
    let models = vec![installed("bbb:1b", 4), installed("aaa:1b", 4)];
    let budget = Some(64 * 1024 * 1024 * 1024);
    assert_eq!(choose_model(&models, budget), Some("bbb:1b"));
}

#[test]
fn available_memory_reports_bytes_or_says_it_cannot() {
    // Not an assertion about the number, which is whatever the box has, but
    // about the shape: bytes rather than the kilobytes /proc/meminfo prints,
    // or None on a machine with no /proc.
    if let Some(bytes) = available_memory() {
        assert!(
            bytes > 16 * 1024 * 1024,
            "MemAvailable is printed in kB and must be scaled to bytes, got {bytes}"
        );
    }
}
