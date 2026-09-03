//! Drives a real daemon over a real unix socket.
//!
//! Nothing here is stubbed. Each test binds a listener in a temporary
//! directory, connects over `UnixStream` and speaks the same
//! newline-delimited JSON the pane speaks, because the properties under test
//! are properties of the socket: that two attached clients see one event
//! stream, and that a client which drops and comes back with `resume_seq`
//! gets exactly what it missed.
//!
//! The persisted events the tests use are the `backend_spawn` errors an
//! `op:"send"` raises. This phase ships no backend, so every send fails to
//! spawn one, and a failure that is conversation-scoped is a real persisted
//! event with a real `seq`. That is enough to exercise replay without
//! pretending a backend exists.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::task::JoinHandle;
use uuid::Uuid;

use ask_daemon::server::{placeholder_backends, Daemon};

/// How long any single read may take before the test gives up.
const PATIENCE: Duration = Duration::from_secs(5);

/// A daemon on a socket in a directory that removes itself.
struct Harness {
    root: PathBuf,
    socket: PathBuf,
    serving: JoinHandle<()>,
}

impl Harness {
    /// Bind a daemon and start accepting.
    async fn start() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-srv-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        let socket = root.join("dots-ask.sock");
        let daemon = Daemon::bind(socket.clone(), root.join("state"), placeholder_backends())
            .expect("the daemon binds");
        assert_eq!(daemon.socket(), socket.as_path());
        Self {
            root,
            socket,
            serving: tokio::spawn(daemon.serve()),
        }
    }

    /// A fresh connection to this daemon.
    async fn client(&self) -> Client {
        Client::connect(&self.socket).await
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.serving.abort();
        drop(fs::remove_dir_all(&self.root));
    }
}

/// One connected client, speaking one JSON object per line.
struct Client {
    lines: Lines<BufReader<OwnedReadHalf>>,
    writer: OwnedWriteHalf,
}

impl Client {
    async fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket)
            .await
            .expect("the socket accepts a connection");
        let (reader, writer) = stream.into_split();
        Self {
            lines: BufReader::new(reader).lines(),
            writer,
        }
    }

    /// Send one frame.
    async fn send(&mut self, frame: &Value) {
        let mut line = frame.to_string();
        line.push('\n');
        self.writer
            .write_all(line.as_bytes())
            .await
            .expect("the daemon accepts the write");
    }

    /// Send a line verbatim, including one the schema would reject.
    async fn send_raw(&mut self, line: &str) {
        self.writer
            .write_all(format!("{line}\n").as_bytes())
            .await
            .expect("the daemon accepts the write");
    }

    /// Read the next event, failing rather than hanging.
    async fn next_event(&mut self) -> Value {
        let line = tokio::time::timeout(PATIENCE, self.lines.next_line())
            .await
            .expect("the daemon answered in time")
            .expect("the connection stayed readable")
            .expect("the daemon did not hang up");
        serde_json::from_str(&line).expect("the daemon sent valid JSON")
    }

    /// Read the next event and assert which one it is.
    async fn expect_event(&mut self, name: &str) -> Value {
        let event = self.next_event().await;
        assert_eq!(event["event"], json!(name), "unexpected event: {event}");
        event
    }

    /// Say hello and read the whole handshake.
    ///
    /// Returns the replayed events and the `seq_head` that `ready` carried,
    /// so a test can assert on the replay itself rather than on a count.
    async fn hello(&mut self, resume_seq: Option<u64>) -> (Vec<Value>, u64) {
        self.send(&json!({"op": "hello", "protocol": 1, "resume_seq": resume_seq}))
            .await;
        let mut replay = Vec::new();
        let seq_head = loop {
            let event = self.next_event().await;
            if event["event"] == json!("ready") {
                assert_eq!(event["protocol"], json!(1));
                assert_eq!(event["seq"], Value::Null, "ready is ephemeral");
                assert_eq!(event["conversation"], Value::Null, "ready is ephemeral");
                break event["seq_head"].as_u64().expect("seq_head is a number");
            }
            replay.push(event);
        };
        self.expect_event("backends").await;
        (replay, seq_head)
    }

    /// Create a thread and read the `conversations` reply.
    async fn new_thread(&mut self, id: Uuid) {
        self.send(&json!({
            "op": "new", "conversation": id, "backend": "claude-code",
            "model": null, "cwd": "/tmp", "title": null
        }))
        .await;
        self.expect_event("conversations").await;
    }

    /// Close the write half, the way a client that has asked for everything
    /// it wants does, while still reading the answers.
    async fn half_close(&mut self) {
        self.writer.shutdown().await.expect("the write half closes");
    }

    /// Send a message, which in this phase always fails to spawn a backend.
    async fn send_text(&mut self, id: Uuid, text: &str) {
        self.send(&json!({
            "op": "send", "conversation": id,
            "blocks": [{"kind": "text", "text": text}]
        }))
        .await;
    }
}

/// The `seq` values of a run of events, in order.
fn seqs(events: &[Value]) -> Vec<u64> {
    events
        .iter()
        .map(|event| event["seq"].as_u64().expect("a persisted event has a seq"))
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_answers_with_ready_then_backends() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;

    client
        .send(&json!({"op": "hello", "protocol": 1, "resume_seq": null}))
        .await;
    let ready = client.expect_event("ready").await;
    assert_eq!(ready["seq_head"], json!(0), "an empty store starts at 0");

    let backends = client.expect_event("backends").await;
    assert_eq!(backends["seq"], Value::Null, "backends is ephemeral");
    assert_eq!(backends["conversation"], Value::Null);
    let items = backends["items"].as_array().expect("items is an array");
    assert_eq!(items.len(), 5, "every backend the spec names is listed");
    for item in items {
        assert_eq!(
            item["state"],
            json!("unconfigured"),
            "no backend runs in this phase"
        );
        assert!(
            item["detail"].is_string(),
            "an unready backend explains why"
        );
        assert!(item["models"].is_array(), "models is empty, never null");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn the_socket_is_only_readable_by_its_owner() {
    use std::os::unix::fs::PermissionsExt;

    let harness = Harness::start().await;
    let mode = fs::metadata(&harness.socket)
        .expect("the socket exists")
        .permissions()
        .mode();
    assert_eq!(
        mode & 0o777,
        0o600,
        "the socket mode is the only gate on this protocol"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn two_clients_see_the_same_events() {
    let harness = Harness::start().await;
    let mut alice = harness.client().await;
    let mut bob = harness.client().await;
    alice.hello(None).await;
    bob.hello(None).await;

    let thread = Uuid::new_v4();
    alice.new_thread(thread).await;

    // Three sends, so an ordering mistake shows up rather than a coin flip.
    for text in ["one", "two", "three"] {
        alice.send_text(thread, text).await;
    }

    let mut from_alice = Vec::new();
    let mut from_bob = Vec::new();
    for _ in 0..3 {
        from_alice.push(alice.expect_event("error").await);
        from_bob.push(bob.expect_event("error").await);
    }

    assert_eq!(
        from_alice, from_bob,
        "both clients must see one event stream"
    );
    assert_eq!(seqs(&from_alice), vec![1, 2, 3], "and see it in order");
    for event in &from_alice {
        assert_eq!(
            event["kind"],
            json!("backend_spawn"),
            "a send with no backend fails to spawn one"
        );
        assert_eq!(
            event["conversation"],
            json!(thread),
            "a conversation-scoped error names its thread"
        );
        assert_eq!(event["fatal"], json!(false));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reconnect_receives_exactly_the_events_it_missed() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();

    let mut alice = harness.client().await;
    let (replay, seq_head) = alice.hello(None).await;
    assert!(replay.is_empty(), "an empty store replays nothing");
    assert_eq!(seq_head, 0);
    alice.new_thread(thread).await;
    for text in ["one", "two", "three"] {
        alice.send_text(thread, text).await;
    }
    let mut seen = Vec::new();
    for _ in 0..3 {
        seen.push(alice.expect_event("error").await);
    }
    assert_eq!(seqs(&seen), vec![1, 2, 3]);

    // Alice goes away, and the world moves on without her.
    drop(alice);
    let mut bob = harness.client().await;
    let (bob_replay, bob_head) = bob.hello(None).await;
    assert_eq!(
        seqs(&bob_replay),
        vec![1, 2, 3],
        "a cold start replays the whole store"
    );
    assert_eq!(bob_head, 3);
    for text in ["four", "five"] {
        bob.send_text(thread, text).await;
    }
    for _ in 0..2 {
        bob.expect_event("error").await;
    }

    // Alice comes back holding seq 3.
    let mut alice = harness.client().await;
    let (missed, head) = alice.hello(Some(3)).await;
    assert_eq!(
        seqs(&missed),
        vec![4, 5],
        "a resume must deliver every missed event and nothing else"
    );
    assert_eq!(head, 5, "ready reports the head at connect time");

    // And the live stream picks up from there with no repeat.
    bob.send_text(thread, "six").await;
    let live = alice.expect_event("error").await;
    assert_eq!(
        live["seq"],
        json!(6),
        "the pump must not resend the replay it already flushed"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_replay_that_spans_two_threads_stays_in_seq_order() {
    let harness = Harness::start().await;
    let left = Uuid::new_v4();
    let right = Uuid::new_v4();

    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(left).await;
    alice.new_thread(right).await;
    for round in 0..3 {
        alice.send_text(left, &format!("left {round}")).await;
        alice.send_text(right, &format!("right {round}")).await;
    }
    for _ in 0..6 {
        alice.expect_event("error").await;
    }

    let mut bob = harness.client().await;
    let (replay, head) = bob.hello(None).await;
    assert_eq!(seqs(&replay), vec![1, 2, 3, 4, 5, 6]);
    assert_eq!(head, 6);
    let threads: Vec<&Value> = replay.iter().map(|event| &event["conversation"]).collect();
    assert_eq!(
        threads,
        vec![
            &json!(left),
            &json!(right),
            &json!(left),
            &json!(right),
            &json!(left),
            &json!(right)
        ],
        "the merge must interleave by seq, not group by file"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn open_sends_only_what_the_client_does_not_hold() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;
    for text in ["one", "two", "three"] {
        alice.send_text(thread, text).await;
    }
    for _ in 0..3 {
        alice.expect_event("error").await;
    }

    let mut bob = harness.client().await;
    bob.send(&json!({"op": "open", "conversation": thread, "from_seq": 1}))
        .await;
    let mut got = Vec::new();
    for _ in 0..2 {
        got.push(bob.expect_event("error").await);
    }
    assert_eq!(
        seqs(&got),
        vec![2, 3],
        "open sends strictly greater than from_seq"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn open_with_a_null_cursor_sends_the_whole_thread() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;
    alice.send_text(thread, "one").await;
    alice.expect_event("error").await;

    let mut bob = harness.client().await;
    bob.send(&json!({"op": "open", "conversation": thread, "from_seq": null}))
        .await;
    let event = bob.expect_event("error").await;
    assert_eq!(
        event["seq"],
        json!(1),
        "null means the client holds nothing"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unknown_op_draws_a_connection_scoped_error_and_the_line_is_ignored() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;

    client.send_raw(r#"{"op":"opne","protocol":1}"#).await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(error["message"], json!("unknown op \"opne\""));
    assert_eq!(error["seq"], Value::Null, "bad_request names no thread");
    assert_eq!(error["conversation"], Value::Null);
    assert_eq!(
        error["fatal"],
        json!(false),
        "a connection-scoped error kills no thread"
    );

    // The connection stays open, which is the point of not closing it.
    client.send(&json!({"op": "list", "limit": 50})).await;
    client.expect_event("conversations").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_line_that_is_not_json_does_not_close_the_connection() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;

    client.send_raw("this is not a frame").await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));

    client.send(&json!({"op": "list", "limit": 50})).await;
    client.expect_event("conversations").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn new_with_an_unknown_backend_is_a_connection_scoped_error() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;

    let thread = Uuid::new_v4();
    client
        .send(&json!({
            "op": "new", "conversation": thread, "backend": "not-a-backend",
            "model": null, "cwd": "/tmp", "title": null
        }))
        .await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(error["message"], json!("unknown backend \"not-a-backend\""));
    assert_eq!(
        error["conversation"],
        Value::Null,
        "no thread exists to file it against"
    );

    // And nothing was created.
    client.send(&json!({"op": "list", "limit": 50})).await;
    let list = client.expect_event("conversations").await;
    assert_eq!(list["items"].as_array().expect("items").len(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_op_naming_an_unknown_thread_is_a_connection_scoped_error() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let ghost = Uuid::new_v4();

    for frame in [
        json!({"op": "open", "conversation": ghost, "from_seq": null}),
        json!({"op": "send", "conversation": ghost,
               "blocks": [{"kind": "text", "text": "hi"}]}),
        json!({"op": "interrupt", "conversation": ghost}),
        json!({"op": "delete", "conversation": ghost}),
    ] {
        client.send(&frame).await;
        let error = client.expect_event("error").await;
        assert_eq!(error["kind"], json!("bad_request"), "for {frame}");
        assert_eq!(
            error["message"],
            json!(format!("unknown conversation {ghost}"))
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_block_missing_its_required_field_is_rejected() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut client = harness.client().await;
    client.hello(None).await;
    client.new_thread(thread).await;

    client
        .send(&json!({"op": "send", "conversation": thread,
                      "blocks": [{"kind": "image", "mime": "image/png"}]}))
        .await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(
        error["message"],
        json!("send block of kind \"image\" carries no path")
    );

    client
        .send(&json!({"op": "send", "conversation": thread, "blocks": []}))
        .await;
    let empty = client.expect_event("error").await;
    assert_eq!(empty["message"], json!("send carries no blocks"));
}

#[tokio::test(flavor = "multi_thread")]
async fn list_and_delete_answer_with_conversations() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;

    let first = Uuid::new_v4();
    let second = Uuid::new_v4();
    client.new_thread(first).await;
    client.new_thread(second).await;

    client.send(&json!({"op": "list", "limit": 50})).await;
    let list = client.expect_event("conversations").await;
    assert_eq!(list["items"].as_array().expect("items").len(), 2);
    assert_eq!(list["seq"], Value::Null, "conversations is ephemeral");

    client
        .send(&json!({"op": "delete", "conversation": first}))
        .await;
    let after = client.expect_event("conversations").await;
    let items = after["items"].as_array().expect("items");
    assert_eq!(items.len(), 1, "delete answers with a fresh list");
    assert_eq!(items[0]["id"], json!(second));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_thread_carries_the_metadata_the_client_minted() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;

    let thread = Uuid::new_v4();
    client
        .send(&json!({
            "op": "new", "conversation": thread, "backend": "ollama",
            "model": "llama3", "cwd": "/home/matus/dots", "title": "a title"
        }))
        .await;
    let reply = client.expect_event("conversations").await;
    let row = &reply["items"].as_array().expect("items")[0];
    assert_eq!(row["id"], json!(thread));
    assert_eq!(row["backend"], json!("ollama"));
    assert_eq!(row["model"], json!("llama3"));
    assert_eq!(row["cwd"], json!("/home/matus/dots"));
    assert_eq!(row["title"], json!("a title"));
    assert_eq!(row["turns"], json!(0), "a fresh thread has closed no turn");
    assert!(row["updated_ms"].as_u64().expect("updated_ms") > 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_new_on_the_same_id_is_refused() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let thread = Uuid::new_v4();
    client.new_thread(thread).await;

    client
        .send(&json!({
            "op": "new", "conversation": thread, "backend": "claude-code",
            "model": null, "cwd": "/tmp", "title": null
        }))
        .await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(
        error["message"],
        json!(format!("conversation {thread} already exists"))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn answering_a_permission_nobody_asked_for_is_refused() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let thread = Uuid::new_v4();
    client.new_thread(thread).await;

    client
        .send(&json!({
            "op": "permission", "conversation": thread, "request": "req-1",
            "decision": "allow", "scope": "once",
            "updated_input": null, "message": null
        }))
        .await;
    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(
        error["message"],
        json!(format!(
            "no permission request \"req-1\" is open on {thread}"
        ))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn interrupting_an_idle_thread_emits_nothing() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let thread = Uuid::new_v4();
    client.new_thread(thread).await;

    client
        .send(&json!({"op": "interrupt", "conversation": thread}))
        .await;
    // Nothing is due, so the next thing the client sees is the answer to the
    // frame after it. A stray turn_end would land here instead and fail.
    client.send(&json!({"op": "list", "limit": 50})).await;
    client.expect_event("conversations").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_client_that_stops_sending_still_receives_what_it_asked_for() {
    // Found by hand with socat, which writes its frames and then half-closes.
    // Ending the connection's fan-out on a read EOF dropped the event the
    // last frame had just produced, and the pane would lose the tail of a
    // turn the same way.
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut client = harness.client().await;
    client.hello(None).await;
    client.new_thread(thread).await;
    client.send_text(thread, "the last thing i will say").await;
    client.half_close().await;

    let event = client.expect_event("error").await;
    assert_eq!(
        event["seq"],
        json!(1),
        "a half-closed client must still get the event its last frame raised"
    );
    assert_eq!(event["kind"], json!("backend_spawn"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_client_that_leaves_does_not_stop_the_others() {
    // emit walks every attached client under the lock, so a dead one has to
    // be pruned there rather than blocking or failing the whole fan-out.
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;

    let mut bob = harness.client().await;
    bob.hello(None).await;
    drop(bob);

    for text in ["one", "two"] {
        alice.send_text(thread, text).await;
    }
    let mut seen = Vec::new();
    for _ in 0..2 {
        seen.push(alice.expect_event("error").await);
    }
    assert_eq!(seqs(&seen), vec![1, 2], "the survivor keeps its stream");
}

#[tokio::test(flavor = "multi_thread")]
async fn open_leaves_the_live_subscription_alone() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;
    alice.send_text(thread, "one").await;
    assert_eq!(alice.expect_event("error").await["seq"], json!(1));

    // Re-read the thread from the start, then keep going live.
    alice
        .send(&json!({"op": "open", "conversation": thread, "from_seq": null}))
        .await;
    assert_eq!(
        alice.expect_event("error").await["seq"],
        json!(1),
        "open re-sends what the client asked for"
    );

    alice.send_text(thread, "two").await;
    assert_eq!(
        alice.expect_event("error").await["seq"],
        json!(2),
        "and the subscription carries on afterwards"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_hello_re_attaches_without_doubling_the_stream() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;
    alice.send_text(thread, "one").await;
    assert_eq!(alice.expect_event("error").await["seq"], json!(1));

    let (replay, head) = alice.hello(Some(1)).await;
    assert!(replay.is_empty(), "the client already holds seq 1");
    assert_eq!(head, 1);

    alice.send_text(thread, "two").await;
    let event = alice.expect_event("error").await;
    assert_eq!(event["seq"], json!(2));

    // A doubled registration would deliver seq 2 twice, so the next thing
    // the client sees must be the answer to the frame after it.
    alice.send(&json!({"op": "list", "limit": 50})).await;
    alice.expect_event("conversations").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_client_that_never_said_hello_still_gets_its_own_replies() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;

    client.send(&json!({"op": "list", "limit": 50})).await;
    let list = client.expect_event("conversations").await;
    assert_eq!(list["items"].as_array().expect("items").len(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_daemon_refuses_the_live_socket() {
    let harness = Harness::start().await;
    let second = Daemon::bind(
        harness.socket.clone(),
        harness.root.join("state"),
        placeholder_backends(),
    );
    match second {
        Ok(_) => panic!("a live socket must not be stolen from the daemon serving it"),
        Err(err) => assert!(
            err.to_string().contains("already serving"),
            "unhelpful error: {err}"
        ),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_socket_left_by_a_dead_run_is_replaced() {
    let root = std::env::temp_dir().join(format!("dots-ask-stale-{}", Uuid::new_v4()));
    fs::create_dir_all(&root).expect("temp root is creatable");
    let socket = root.join("dots-ask.sock");

    // A socket file with nobody behind it is exactly what a crash leaves.
    drop(std::os::unix::net::UnixListener::bind(&socket).expect("the placeholder socket binds"));
    assert!(socket.exists(), "the stale file is there");

    let daemon = Daemon::bind(socket.clone(), root.join("state"), placeholder_backends())
        .expect("a stale socket is removed rather than fatal");
    let serving = tokio::spawn(daemon.serve());
    let mut client = Client::connect(&socket).await;
    client.hello(None).await;

    serving.abort();
    drop(fs::remove_dir_all(&root));
}
