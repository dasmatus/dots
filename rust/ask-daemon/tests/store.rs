//! Proves the transcript is the source of truth across a restart.
//!
//! Every test here works against a real directory rather than a fake
//! filesystem, because the properties being checked are properties of the
//! files: that a reload reads back what the last run wrote, that the `seq`
//! counter picks up above the stored head instead of reusing numbers, and
//! that a turn a restart cut short comes back closed.
//!
//! Time is passed in rather than read from the clock, so a duration in an
//! assertion is a fixed number and not a race.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::json;
use uuid::Uuid;

use ask_daemon::proto::{
    ConversationMeta, ErrorKind, EventBody, ServerEvent, StopReason, ToolOrigin,
};
use ask_daemon::session::TurnState;
use ask_daemon::store::{Loaded, Store};
use ask_daemon::AskError;

/// A directory that removes itself, so a failing test leaves nothing behind.
struct TempRoot(PathBuf);

impl TempRoot {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("dots-ask-store-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).expect("temp root is creatable");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.0));
    }
}

/// Open the store at a root, failing the test rather than the caller.
fn open(root: &Path, now_ms: u64) -> Loaded {
    Store::open(root.to_path_buf(), now_ms).expect("the store opens")
}

/// Metadata for a thread the client just minted.
fn meta(id: Uuid, now_ms: u64) -> ConversationMeta {
    ConversationMeta {
        id,
        title: None,
        backend: "claude-code".to_owned(),
        model: Some("claude-opus-5".to_owned()),
        cwd: PathBuf::from("/home/matus/Dokumente/codeberg/personal/dots"),
        updated_ms: now_ms,
        turns: 0,
    }
}

/// One whole turn, as a backend would produce it.
fn a_finished_turn(turn: Uuid) -> Vec<EventBody> {
    vec![
        EventBody::TurnStart {
            turn: Some(turn),
            backend: "claude-code".to_owned(),
            model: Some("claude-opus-5".to_owned()),
            started_ms: 1_000,
        },
        EventBody::TextDelta {
            turn: Some(turn),
            block: 0,
            text: "The".to_owned(),
        },
        EventBody::TextDelta {
            turn: Some(turn),
            block: 0,
            text: " crate".to_owned(),
        },
        EventBody::ToolCall {
            turn: Some(turn),
            call: "toolu_0147".to_owned(),
            name: "Write".to_owned(),
            display_name: Some("Write".to_owned()),
            summary: Some("a.txt".to_owned()),
            input: json!({"file_path": "/tmp/a.txt"}),
            origin: ToolOrigin::Harness,
        },
        EventBody::TurnEnd {
            turn: Some(turn),
            stop: StopReason::EndTurn,
            text: Some("Created a.txt.".to_owned()),
            duration_ms: 500,
        },
    ]
}

#[test]
fn append_then_reload_reproduces_the_event_sequence() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let turn = Uuid::new_v4();

    let written: Vec<ServerEvent> = {
        let mut loaded = open(root.path(), 1_000);
        loaded.store.create(meta(id, 1_000)).expect("create works");
        a_finished_turn(turn)
            .into_iter()
            .map(|body| {
                loaded
                    .store
                    .record(id, body, 1_500)
                    .expect("recording works")
            })
            .collect()
    };

    let reloaded = open(root.path(), 9_000);
    let read_back = reloaded
        .store
        .events_after(None)
        .expect("the transcript reads back");
    assert_eq!(read_back, written, "a reload changed the event sequence");
    assert_eq!(
        reloaded.recovered,
        Vec::new(),
        "a turn that closed must not be recovered"
    );
}

#[test]
fn the_seq_space_is_dense_and_survives_a_reload() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let turn = Uuid::new_v4();

    {
        let mut loaded = open(root.path(), 1_000);
        loaded.store.create(meta(id, 1_000)).expect("create works");
        for body in a_finished_turn(turn) {
            loaded.store.record(id, body, 1_500).expect("record works");
        }
        assert_eq!(loaded.store.seq_head(), 5, "five events, five seqs");
    }

    let mut reloaded = open(root.path(), 9_000);
    assert_eq!(
        reloaded.store.seq_head(),
        5,
        "the head must resume where the file ends"
    );
    let next = reloaded
        .store
        .record(
            id,
            EventBody::Error {
                kind: ErrorKind::BackendSpawn,
                message: "nope".to_owned(),
                fatal: false,
            },
            9_000,
        )
        .expect("record works");
    assert_eq!(next.seq, Some(6), "a restart must not reuse a seq");

    let all = reloaded.store.events_after(None).expect("reads back");
    let seqs: Vec<Option<u64>> = all.iter().map(|event| event.seq).collect();
    assert_eq!(
        seqs,
        vec![Some(1), Some(2), Some(3), Some(4), Some(5), Some(6)],
        "the seq space must have no holes"
    );
}

#[test]
fn an_in_flight_turn_is_marked_interrupted_on_reload() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let turn = Uuid::new_v4();

    {
        let mut loaded = open(root.path(), 1_000);
        loaded.store.create(meta(id, 1_000)).expect("create works");
        // Everything but the turn_end, which is what a killed daemon leaves.
        for body in a_finished_turn(turn)
            .into_iter()
            .filter(|body| !matches!(body, EventBody::TurnEnd { .. }))
        {
            loaded.store.record(id, body, 1_000).expect("record works");
        }
    }

    let reloaded = open(root.path(), 6_000);
    assert_eq!(
        reloaded.recovered.len(),
        1,
        "exactly one turn was left open"
    );
    let recovered = &reloaded.recovered[0];
    assert_eq!(recovered.conversation, Some(id));
    assert_eq!(recovered.seq, Some(5), "the repair takes the next seq");
    assert_eq!(
        recovered.body,
        EventBody::TurnEnd {
            turn: Some(turn),
            stop: StopReason::Interrupted,
            text: None,
            duration_ms: 5_000,
        },
        "a restart closes the turn as interrupted, with no summary text"
    );

    let session = reloaded.sessions.get(&id).expect("the session exists");
    assert_eq!(
        session.turn_state(),
        &TurnState::Idle,
        "the recovered session must be idle"
    );

    // And the repair is durable, not just in memory.
    let again = open(root.path(), 7_000);
    assert!(
        again.recovered.is_empty(),
        "a second reload must not repair the same turn twice"
    );
    let tail = again
        .store
        .events_after(Some(4))
        .expect("the transcript reads back");
    assert_eq!(tail, vec![recovered.clone()], "the repair was written down");
}

#[test]
fn a_reload_counts_the_recovered_turn() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();

    {
        let mut loaded = open(root.path(), 1_000);
        loaded.store.create(meta(id, 1_000)).expect("create works");
        loaded
            .store
            .record(
                id,
                EventBody::TurnStart {
                    turn: Some(Uuid::new_v4()),
                    backend: "claude-code".to_owned(),
                    model: None,
                    started_ms: 1_000,
                },
                1_000,
            )
            .expect("record works");
        assert_eq!(
            loaded.store.meta(id).expect("meta exists").turns,
            0,
            "an open turn has not closed"
        );
    }

    let reloaded = open(root.path(), 4_000);
    assert_eq!(
        reloaded.store.meta(id).expect("meta exists").turns,
        1,
        "the recovered turn_end counts like any other"
    );
}

#[test]
fn an_ephemeral_body_never_reaches_disk() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);
    loaded.store.create(meta(id, 1_000)).expect("create works");

    let event = loaded
        .store
        .record(
            id,
            EventBody::Ready {
                protocol: 1,
                artifact_base: None,
                seq_head: 0,
            },
            1_000,
        )
        .expect("record works");
    assert_eq!(event.seq, None, "an ephemeral reply takes no seq");
    assert_eq!(event.conversation, None, "and names no thread");
    assert_eq!(loaded.store.seq_head(), 0, "and burns no number");
    assert!(
        loaded
            .store
            .events_after(None)
            .expect("reads back")
            .is_empty(),
        "nothing should have been written"
    );

    // The same for the connection-scoped half of error.
    loaded
        .store
        .record(
            id,
            EventBody::Error {
                kind: ErrorKind::Store,
                message: "disk is gone".to_owned(),
                fatal: false,
            },
            1_000,
        )
        .expect("record works");
    assert_eq!(
        loaded.store.seq_head(),
        0,
        "a store error cannot persist itself"
    );
}

#[test]
fn recording_against_a_thread_the_index_does_not_have_is_refused() {
    // Without the guard this call succeeds, spends a seq and writes a line
    // into a transcript that events_after will never open, because that
    // function walks the index. The hole it leaves in hello replay is
    // permanent and silent, so the store has to refuse rather than warn.
    let root = TempRoot::new();
    let ghost = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);

    let outcome = loaded.store.record(
        ghost,
        EventBody::TextDelta {
            turn: None,
            block: 0,
            text: "into the void".to_owned(),
        },
        1_000,
    );

    match outcome {
        Ok(event) => panic!("an unindexed thread must not be recorded against: {event:?}"),
        Err(AskError::UnknownConversation { id }) => assert_eq!(id, ghost, "the error names it"),
        Err(other) => panic!("wrong error for an unindexed thread: {other}"),
    }

    assert_eq!(
        loaded.store.seq_head(),
        0,
        "a refused record must not spend a seq"
    );
    assert!(
        !root
            .path()
            .join("conversations")
            .join(format!("{ghost}.jsonl"))
            .exists(),
        "and must not leave a transcript nothing will read"
    );
}

#[test]
fn a_thread_that_was_deleted_stops_accepting_events() {
    // The same guard, reached the way a real caller would: a backend still
    // streaming into a thread the user just removed.
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);
    loaded.store.create(meta(id, 1_000)).expect("create works");
    loaded
        .store
        .record(
            id,
            EventBody::TextDelta {
                turn: None,
                block: 0,
                text: "before".to_owned(),
            },
            1_000,
        )
        .expect("record works while the thread exists");

    loaded.store.delete(id).expect("delete works");

    let outcome = loaded.store.record(
        id,
        EventBody::TextDelta {
            turn: None,
            block: 1,
            text: "after".to_owned(),
        },
        2_000,
    );
    assert!(
        matches!(outcome, Err(AskError::UnknownConversation { .. })),
        "a deleted thread must not quietly grow a new transcript"
    );
    assert_eq!(loaded.store.seq_head(), 1, "and must not spend a seq");
}

#[test]
fn conversation_events_after_is_strictly_greater() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let turn = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);
    loaded.store.create(meta(id, 1_000)).expect("create works");
    for body in a_finished_turn(turn) {
        loaded.store.record(id, body, 1_000).expect("record works");
    }

    let from_three = loaded
        .store
        .conversation_events_after(id, Some(3))
        .expect("reads back");
    assert_eq!(
        from_three.iter().map(|e| e.seq).collect::<Vec<_>>(),
        vec![Some(4), Some(5)],
        "open must not resend what the client already holds"
    );

    let everything = loaded
        .store
        .conversation_events_after(id, None)
        .expect("reads back");
    assert_eq!(everything.len(), 5, "null means the client holds nothing");
}

#[test]
fn replay_merges_two_threads_in_seq_order() {
    let root = TempRoot::new();
    let left = Uuid::new_v4();
    let right = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);
    loaded
        .store
        .create(meta(left, 1_000))
        .expect("create works");
    loaded
        .store
        .create(meta(right, 1_000))
        .expect("create works");

    // Interleave, so a per-file read that forgot to merge would show it.
    let mut expected = Vec::new();
    for round in 0..3_u32 {
        for id in [left, right] {
            let event = loaded
                .store
                .record(
                    id,
                    EventBody::TextDelta {
                        turn: None,
                        block: round,
                        text: format!("{id}-{round}"),
                    },
                    1_000,
                )
                .expect("record works");
            expected.push(event);
        }
    }

    let replay = loaded.store.events_after(None).expect("reads back");
    assert_eq!(
        replay, expected,
        "replay must be in seq order across threads"
    );
}

#[test]
fn list_pages_newest_first_by_updated_ms() {
    let root = TempRoot::new();
    let mut loaded = open(root.path(), 1_000);
    let ids: Vec<Uuid> = (0..3).map(|_| Uuid::new_v4()).collect();
    for (offset, id) in ids.iter().enumerate() {
        let stamp = 1_000 + (offset as u64) * 1_000;
        loaded.store.create(meta(*id, stamp)).expect("create works");
    }

    let page = loaded.store.list(2, None);
    assert_eq!(
        page.iter().map(|row| row.updated_ms).collect::<Vec<_>>(),
        vec![3_000, 2_000],
        "the newest thread comes first"
    );

    let next = loaded.store.list(2, Some(2_000));
    assert_eq!(
        next.iter().map(|row| row.updated_ms).collect::<Vec<_>>(),
        vec![1_000],
        "the cursor must exclude the row it paged from"
    );
}

#[test]
fn delete_removes_the_thread_and_its_transcript() {
    let root = TempRoot::new();
    let id = Uuid::new_v4();
    let mut loaded = open(root.path(), 1_000);
    loaded.store.create(meta(id, 1_000)).expect("create works");
    loaded
        .store
        .record(
            id,
            EventBody::TextDelta {
                turn: None,
                block: 0,
                text: "gone soon".to_owned(),
            },
            1_000,
        )
        .expect("record works");

    let transcript = root
        .path()
        .join("conversations")
        .join(format!("{id}.jsonl"));
    assert!(transcript.exists(), "the transcript should exist first");

    loaded.store.delete(id).expect("delete works");
    assert!(!loaded.store.contains(id), "the index row is gone");
    assert!(!transcript.exists(), "the transcript is gone");

    let reloaded = open(root.path(), 2_000);
    assert!(
        reloaded.store.list(50, None).is_empty(),
        "the deletion survives a reload"
    );
}

#[test]
fn a_missing_state_root_is_created_on_demand() {
    let root = TempRoot::new();
    let nested = root.path().join("deep").join("state");
    let loaded = Store::open(nested.clone(), 1_000).expect("the store creates its own directories");
    assert!(nested.join("conversations").is_dir());
    assert_eq!(loaded.store.seq_head(), 0);
}
