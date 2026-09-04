//! Pins the turn state machine and the pending-permission table.
//!
//! The interesting property is that folding a stored transcript and watching
//! live events reach the same state, since that is what lets a restart pick
//! up where the last run stopped. Every test here drives `apply` with the
//! same bodies the store would hand back.

use serde_json::json;
use uuid::Uuid;

use ask_daemon::proto::{EventBody, StopReason, ToolOrigin};
use ask_daemon::session::{Session, TurnState};

/// A `permission_request` body for one call.
fn permission(request: &str, call: &str, withdrawn: bool) -> EventBody {
    EventBody::PermissionRequest {
        request: request.to_owned(),
        call: call.to_owned(),
        name: "Write".to_owned(),
        display_name: Some("Write".to_owned()),
        description: Some("a.txt".to_owned()),
        input: json!({"file_path": "/tmp/a.txt"}),
        suggestions: Vec::new(),
        withdrawn,
    }
}

/// A `tool_result` body for one call.
fn tool_result(call: &str) -> EventBody {
    EventBody::ToolResult {
        call: call.to_owned(),
        ok: true,
        content: "written".to_owned(),
        truncated: false,
    }
}

#[test]
fn a_new_session_is_idle() {
    let session = Session::new(Uuid::new_v4());
    assert_eq!(session.turn_state(), &TurnState::Idle);
    assert_eq!(session.running_turn(), None);
    assert_eq!(session.pending_count(), 0);
}

#[test]
fn a_turn_opens_and_closes() {
    let mut session = Session::new(Uuid::new_v4());
    let started = session
        .begin_turn("claude-code".to_owned(), Some("opus".to_owned()), 1_000)
        .expect("an idle session opens a turn");

    let EventBody::TurnStart { turn, .. } = started else {
        panic!("begin_turn produced the wrong event");
    };
    assert_eq!(session.running_turn(), turn, "the turn id must match");

    let ended = session
        .end_turn(StopReason::EndTurn, Some("done".to_owned()), 4_500)
        .expect("a running session closes its turn");
    assert_eq!(
        ended,
        EventBody::TurnEnd {
            turn,
            stop: StopReason::EndTurn,
            text: Some("done".to_owned()),
            duration_ms: 3_500,
        },
        "the duration comes from the turn_start stamp"
    );
    assert_eq!(session.turn_state(), &TurnState::Idle);
}

#[test]
fn a_second_turn_cannot_open_while_one_runs() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("claude-code".to_owned(), None, 1_000)
        .expect("the first turn opens");
    assert!(
        session
            .begin_turn("claude-code".to_owned(), None, 1_100)
            .is_none(),
        "a second turn_start would leave the first without a turn_end"
    );
}

#[test]
fn closing_an_idle_session_produces_nothing() {
    let mut session = Session::new(Uuid::new_v4());
    assert!(
        session.end_turn(StopReason::EndTurn, None, 1_000).is_none(),
        "a stray result must not invent a turn the pane never saw"
    );
    assert!(
        session.interrupt(1_000).is_none(),
        "interrupting nothing is not an event"
    );
}

#[test]
fn an_interrupt_closes_the_turn_without_a_summary() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("claude-code".to_owned(), None, 1_000)
        .expect("the turn opens");
    let ended = session.interrupt(3_000).expect("the turn closes");
    let EventBody::TurnEnd {
        stop,
        text,
        duration_ms,
        ..
    } = ended
    else {
        panic!("interrupt produced the wrong event");
    };
    assert_eq!(stop, StopReason::Interrupted);
    assert_eq!(text, None, "an interrupted turn sends no summary");
    assert_eq!(duration_ms, 2_000);
}

#[test]
fn a_clock_that_went_backwards_does_not_underflow() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("claude-code".to_owned(), None, 5_000)
        .expect("the turn opens");
    let ended = session.interrupt(1_000).expect("the turn closes anyway");
    let EventBody::TurnEnd { duration_ms, .. } = ended else {
        panic!("interrupt produced the wrong event");
    };
    assert_eq!(duration_ms, 0, "a backwards clock clamps rather than wraps");
}

#[test]
fn folding_a_transcript_finds_the_turn_a_restart_left_open() {
    let id = Uuid::new_v4();
    let turn = Uuid::new_v4();
    let transcript = vec![
        EventBody::TurnStart {
            turn: Some(turn),
            backend: "claude-code".to_owned(),
            model: None,
            started_ms: 1_000,
        },
        EventBody::TextDelta {
            turn: Some(turn),
            block: 0,
            text: "half a".to_owned(),
        },
        EventBody::ToolCall {
            turn: Some(turn),
            call: "toolu_0147".to_owned(),
            name: "Write".to_owned(),
            display_name: None,
            summary: None,
            input: json!({}),
            origin: ToolOrigin::Harness,
        },
    ];

    let mut session = Session::new(id);
    for body in &transcript {
        session.apply(body);
    }
    assert_eq!(
        session.running_turn(),
        Some(turn),
        "the fold must see the open turn"
    );

    let repair = session.interrupt(6_000).expect("the open turn closes");
    assert_eq!(
        repair,
        EventBody::TurnEnd {
            turn: Some(turn),
            stop: StopReason::Interrupted,
            text: None,
            duration_ms: 5_000,
        }
    );
}

#[test]
fn applying_an_event_twice_changes_nothing() {
    // The server applies a body and then records it, and recovery applies it
    // as part of producing it. Both paths can reach apply for the same event,
    // so it has to be idempotent.
    let mut once = Session::new(Uuid::new_v4());
    let mut twice = Session::new(Uuid::new_v4());
    let bodies = vec![
        EventBody::TurnStart {
            turn: Some(Uuid::new_v4()),
            backend: "claude-code".to_owned(),
            model: None,
            started_ms: 1_000,
        },
        permission("req-1", "toolu_a", false),
        permission("req-2", "toolu_b", false),
        tool_result("toolu_a"),
    ];
    for body in &bodies {
        once.apply(body);
        twice.apply(body);
        twice.apply(body);
    }
    assert_eq!(once.turn_state(), twice.turn_state());
    assert_eq!(once.pending_count(), twice.pending_count());
    assert_eq!(
        once.pending_permission("req-2"),
        twice.pending_permission("req-2")
    );
}

#[test]
fn a_permission_request_is_tracked_until_it_is_answered() {
    let mut session = Session::new(Uuid::new_v4());
    session.apply(&permission("req-1", "toolu_a", false));
    assert_eq!(session.pending_permission("req-1"), Some("toolu_a"));

    assert_eq!(
        session.resolve_permission("req-1"),
        Some("toolu_a".to_owned()),
        "answering returns the call it gated"
    );
    assert_eq!(session.pending_permission("req-1"), None);
    assert_eq!(
        session.resolve_permission("req-1"),
        None,
        "answering twice is an argument the daemon cannot resolve"
    );
}

#[test]
fn a_withdrawn_request_stops_being_answerable() {
    let mut session = Session::new(Uuid::new_v4());
    session.apply(&permission("req-1", "toolu_a", false));
    session.apply(&permission("req-1", "toolu_a", true));
    assert_eq!(
        session.pending_permission("req-1"),
        None,
        "the pane must not answer a withdrawn prompt"
    );
    assert_eq!(session.pending_count(), 0);
}

#[test]
fn a_tool_result_clears_the_request_that_gated_it() {
    let mut session = Session::new(Uuid::new_v4());
    session.apply(&permission("req-1", "toolu_a", false));
    session.apply(&permission("req-2", "toolu_b", false));
    session.apply(&tool_result("toolu_a"));

    assert_eq!(
        session.pending_permission("req-1"),
        None,
        "the tool ran, so its gate was answered"
    );
    assert_eq!(
        session.pending_permission("req-2"),
        Some("toolu_b"),
        "an unrelated request stays open"
    );
}

#[test]
fn closing_a_turn_drops_every_open_request() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("claude-code".to_owned(), None, 1_000)
        .expect("the turn opens");
    session.apply(&permission("req-1", "toolu_a", false));
    session.apply(&permission("req-2", "toolu_b", false));
    assert_eq!(session.pending_count(), 2);

    session.interrupt(2_000).expect("the turn closes");
    assert_eq!(
        session.pending_count(),
        0,
        "nothing can answer a request whose turn is over"
    );
}

// -- adopting what a backend produced --------------------------------------
//
// A backend emits bodies with `turn: None`, because the turn id is minted
// here and never leaves the daemon. `adopt` fills it in, and it is the one
// place that decides whether an event belongs to a turn at all.

/// A `text_delta` the way an adapter emits it, with no turn on it.
fn unstamped_delta() -> EventBody {
    EventBody::TextDelta {
        turn: None,
        block: 0,
        text: "The".to_owned(),
    }
}

/// A `turn_start` the way an adapter emits it.
fn unstamped_turn_start() -> EventBody {
    EventBody::TurnStart {
        turn: None,
        backend: "ollama".to_owned(),
        model: Some("ornith:9b".to_owned()),
        started_ms: 1_000,
    }
}

#[test]
fn adopting_a_turn_start_mints_the_turn_id() {
    let session = Session::new(Uuid::new_v4());
    let EventBody::TurnStart { turn, backend, .. } = session
        .adopt(unstamped_turn_start(), 1_000)
        .expect("an idle session opens a turn")
    else {
        panic!("adopt changed the event type");
    };
    assert!(turn.is_some(), "the daemon mints the id, not the adapter");
    assert_eq!(backend, "ollama", "and carries the rest through");
}

#[test]
fn adopting_does_not_move_the_session_on() {
    // The store is written first and the session folded only once the store
    // has taken the event, so `adopt` has to be free of side effects or a
    // store failure would leave the session ahead of the transcript.
    let session = Session::new(Uuid::new_v4());
    session
        .adopt(unstamped_turn_start(), 1_000)
        .expect("the turn opens");
    assert_eq!(
        session.turn_state(),
        &TurnState::Idle,
        "adopt must not advance the session by itself"
    );
}

#[test]
fn a_second_turn_start_over_a_running_turn_is_dropped() {
    // A backend speaks one turn at a time, and a second turn_start would
    // leave the first with no turn_end, which is the exact shape restart
    // recovery has to repair.
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("ollama".to_owned(), None, 1_000)
        .expect("the turn opens");
    assert!(
        session.adopt(unstamped_turn_start(), 2_000).is_none(),
        "the second turn_start has nowhere to go"
    );
}

#[test]
fn a_delta_takes_the_running_turn_id() {
    let mut session = Session::new(Uuid::new_v4());
    let opened = session
        .begin_turn("ollama".to_owned(), None, 1_000)
        .expect("the turn opens");
    let EventBody::TurnStart { turn: opened, .. } = opened else {
        panic!("begin_turn returned the wrong body");
    };

    let EventBody::TextDelta { turn, text, .. } = session
        .adopt(unstamped_delta(), 1_500)
        .expect("a delta inside a turn is adopted")
    else {
        panic!("adopt changed the event type");
    };
    assert_eq!(turn, opened, "the delta joins the turn that is running");
    assert_eq!(text, "The");
}

#[test]
fn a_delta_with_no_turn_running_is_dropped() {
    // A decoder bug rather than something to persist. Recording it would put
    // an event in the transcript that belongs to no turn, and the pane has
    // nowhere to draw it.
    let session = Session::new(Uuid::new_v4());
    assert!(session.adopt(unstamped_delta(), 1_000).is_none());
}

#[test]
fn the_events_that_correlate_by_call_are_adopted_between_turns() {
    // tool_result, permission_request and diff carry no turn at all and can
    // legitimately arrive with none running, so they must not be dropped by
    // the same rule that drops a stray delta.
    let session = Session::new(Uuid::new_v4());
    assert!(
        session.adopt(tool_result("toolu_a"), 1_000).is_some(),
        "a tool result correlates through call, not through turn"
    );
    assert!(
        session
            .adopt(permission("req-1", "toolu_a", false), 1_000)
            .is_some(),
        "so does a permission request"
    );
}

#[test]
fn an_error_is_adopted_with_no_turn_running() {
    // error can arrive before a turn ever opens, which is what a spawn
    // failure is.
    let session = Session::new(Uuid::new_v4());
    assert!(session
        .adopt(
            EventBody::Error {
                kind: ask_daemon::proto::ErrorKind::BackendSpawn,
                message: "did not start".to_owned(),
                fatal: true,
            },
            1_000
        )
        .is_some());
}

#[test]
fn a_user_message_is_adopted_before_any_turn_exists() {
    // It is emitted when a send is accepted, which is before the turn_start
    // it causes, so the no-turn-running rule must not eat it.
    let session = Session::new(Uuid::new_v4());
    assert!(session
        .adopt(
            EventBody::UserMessage {
                blocks: Vec::new(),
                sent_ms: 1_000,
            },
            1_000
        )
        .is_some());
}

#[test]
fn adopting_a_turn_end_measures_the_turn_it_closes() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("ollama".to_owned(), None, 1_000)
        .expect("the turn opens");
    let EventBody::TurnEnd {
        duration_ms, stop, ..
    } = session
        .adopt(
            EventBody::TurnEnd {
                turn: None,
                stop: StopReason::EndTurn,
                text: Some("done".to_owned()),
                duration_ms: 0,
            },
            4_500,
        )
        .expect("the running turn closes")
    else {
        panic!("adopt changed the event type");
    };
    assert_eq!(
        duration_ms, 3_500,
        "the duration is measured here, not by the adapter"
    );
    assert_eq!(stop, StopReason::EndTurn);
}

#[test]
fn a_turn_end_with_nothing_running_is_dropped() {
    // A stray result from a backend cannot close a turn the pane never saw
    // open, and cannot close one twice.
    let session = Session::new(Uuid::new_v4());
    assert!(session
        .adopt(
            EventBody::TurnEnd {
                turn: None,
                stop: StopReason::EndTurn,
                text: None,
                duration_ms: 0,
            },
            1_000
        )
        .is_none());
}

#[test]
fn a_tool_call_keeps_every_field_the_adapter_set() {
    let mut session = Session::new(Uuid::new_v4());
    session
        .begin_turn("ollama".to_owned(), None, 1_000)
        .expect("the turn opens");
    let EventBody::ToolCall {
        turn,
        call,
        name,
        input,
        origin,
        ..
    } = session
        .adopt(
            EventBody::ToolCall {
                turn: None,
                call: "toolu_a".to_owned(),
                name: "Write".to_owned(),
                display_name: None,
                summary: None,
                input: json!({"file_path": "/tmp/a.txt"}),
                origin: ToolOrigin::Mcp,
            },
            1_100,
        )
        .expect("a tool call inside a turn is adopted")
    else {
        panic!("adopt changed the event type");
    };
    assert!(turn.is_some(), "only the turn is filled in");
    assert_eq!(call, "toolu_a");
    assert_eq!(name, "Write");
    assert_eq!(input, json!({"file_path": "/tmp/a.txt"}));
    assert_eq!(origin, ToolOrigin::Mcp);
}
