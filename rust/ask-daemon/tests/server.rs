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
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use uuid::Uuid;

use ask_daemon::backend::{
    unconfigured_registry, Backend, BackendCommand, BackendContext, BackendHandle, Registry,
    CLAUDE_CODE,
};
use ask_daemon::mcp::McpPool;
use ask_daemon::policy::Policy;
use ask_daemon::proto::{BackendInfo, BackendState, EventBody, SendBlock, StopReason};
use ask_daemon::secrets::SecretStore;
use ask_daemon::server::{Artifacts, Daemon};

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
        Self::with_registry(unconfigured_registry()).await
    }

    /// Bind a daemon that runs the backends `registry` holds.
    async fn with_registry(registry: Arc<Registry>) -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-srv-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        let socket = root.join("dots-ask.sock");
        let daemon = Daemon::bind(
            socket.clone(),
            root.join("state"),
            registry,
            Artifacts::unserved(&root.join("state")).expect("the artifact root opens"),
        )
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

    /// Send a message, which against this registry always fails to spawn a
    /// backend.
    async fn send_text(&mut self, id: Uuid, text: &str) {
        self.send(&json!({
            "op": "send", "conversation": id,
            "blocks": [{"kind": "text", "text": text}]
        }))
        .await;
    }

    /// Read the pair of persisted events one `send` produces.
    ///
    /// A send always records the user's own message first, whether or not
    /// anything answers it, and then, against this registry, the
    /// `backend_spawn` failure. Two events per send, always in that order.
    /// The `error` comes back, because that is the one the ordering tests
    /// were written against.
    async fn expect_send(&mut self) -> Value {
        self.expect_event("user_message").await;
        self.expect_event("error").await
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
        from_alice.push(alice.expect_send().await);
        from_bob.push(bob.expect_send().await);
    }

    assert_eq!(
        from_alice, from_bob,
        "both clients must see one event stream"
    );
    assert_eq!(seqs(&from_alice), vec![2, 4, 6], "and see it in order");
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
        seen.push(alice.expect_send().await);
    }
    assert_eq!(seqs(&seen), vec![2, 4, 6]);

    // Alice goes away, and the world moves on without her.
    drop(alice);
    let mut bob = harness.client().await;
    let (bob_replay, bob_head) = bob.hello(None).await;
    assert_eq!(
        seqs(&bob_replay),
        vec![1, 2, 3, 4, 5, 6],
        "a cold start replays the whole store"
    );
    assert_eq!(bob_head, 6);
    for text in ["four", "five"] {
        bob.send_text(thread, text).await;
    }
    for _ in 0..2 {
        bob.expect_send().await;
    }

    // Alice comes back holding seq 6.
    let mut alice = harness.client().await;
    let (missed, head) = alice.hello(Some(6)).await;
    assert_eq!(
        seqs(&missed),
        vec![7, 8, 9, 10],
        "a resume must deliver every missed event and nothing else"
    );
    assert_eq!(head, 10, "ready reports the head at connect time");

    // And the live stream picks up from there with no repeat.
    bob.send_text(thread, "six").await;
    let live = alice.expect_send().await;
    assert_eq!(
        live["seq"],
        json!(12),
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
        alice.expect_send().await;
    }

    let mut bob = harness.client().await;
    let (replay, head) = bob.hello(None).await;
    assert_eq!(seqs(&replay), (1..=12).collect::<Vec<u64>>());
    assert_eq!(head, 12);
    // Two events per send, so each thread appears in pairs, and the pairs
    // alternate. A merge that grouped by file would put all six left events
    // first.
    let threads: Vec<Value> = replay
        .iter()
        .map(|event| event["conversation"].clone())
        .collect();
    let expected: Vec<Value> = std::iter::repeat_n([json!(left), json!(right)], 3)
        .flatten()
        .flat_map(|thread| [thread.clone(), thread])
        .collect();
    assert_eq!(
        threads, expected,
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
        alice.expect_send().await;
    }

    let mut bob = harness.client().await;
    bob.send(&json!({"op": "open", "conversation": thread, "from_seq": 2}))
        .await;
    let mut got = Vec::new();
    for _ in 0..4 {
        got.push(bob.next_event().await);
    }
    assert_eq!(
        seqs(&got),
        vec![3, 4, 5, 6],
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
    alice.expect_send().await;

    let mut bob = harness.client().await;
    bob.send(&json!({"op": "open", "conversation": thread, "from_seq": null}))
        .await;
    let event = bob.expect_event("user_message").await;
    assert_eq!(
        event["seq"],
        json!(1),
        "null means the client holds nothing"
    );
    assert_eq!(
        bob.expect_event("error").await["seq"],
        json!(2),
        "and the rest of the thread follows it"
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

    assert_eq!(
        client.expect_event("user_message").await["seq"],
        json!(1),
        "a half-closed client must still get what its last frame recorded"
    );
    let event = client.expect_event("error").await;
    assert_eq!(
        event["seq"],
        json!(2),
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
    for _ in 0..4 {
        seen.push(alice.next_event().await);
    }
    assert_eq!(
        seqs(&seen),
        vec![1, 2, 3, 4],
        "the survivor keeps its stream"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn open_leaves_the_live_subscription_alone() {
    let harness = Harness::start().await;
    let thread = Uuid::new_v4();
    let mut alice = harness.client().await;
    alice.hello(None).await;
    alice.new_thread(thread).await;
    alice.send_text(thread, "one").await;
    assert_eq!(alice.expect_send().await["seq"], json!(2));

    // Re-read the thread from the start, then keep going live.
    alice
        .send(&json!({"op": "open", "conversation": thread, "from_seq": null}))
        .await;
    assert_eq!(
        alice.expect_send().await["seq"],
        json!(2),
        "open re-sends what the client asked for"
    );

    alice.send_text(thread, "two").await;
    assert_eq!(
        alice.expect_send().await["seq"],
        json!(4),
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
    assert_eq!(alice.expect_send().await["seq"], json!(2));

    let (replay, head) = alice.hello(Some(2)).await;
    assert!(replay.is_empty(), "the client already holds seq 2");
    assert_eq!(head, 2);

    alice.send_text(thread, "two").await;
    let event = alice.expect_send().await;
    assert_eq!(event["seq"], json!(4));

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
        unconfigured_registry(),
        Artifacts::unserved(&harness.root.join("state")).expect("the artifact root opens"),
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

    let daemon = Daemon::bind(
        socket.clone(),
        root.join("state"),
        unconfigured_registry(),
        Artifacts::unserved(&root.join("state")).expect("the artifact root opens"),
    )
    .expect("a stale socket is removed rather than fatal");
    let serving = tokio::spawn(daemon.serve());
    let mut client = Client::connect(&socket).await;
    client.hello(None).await;

    serving.abort();
    drop(fs::remove_dir_all(&root));
}

// -- attachments and artifacts ---------------------------------------------

/// What one scripted backend was handed: its attachment directory and the
/// blocks of the last send it saw.
type Seen = Arc<Mutex<Option<(PathBuf, Vec<SendBlock>)>>>;

/// A backend that answers every send with a scripted event list.
///
/// It exists because the artifact path runs from `send` through a backend,
/// the shared channel, `pump` and `absorb` before it reaches a client, and
/// there is no way to drive that with `unconfigured_registry()`, which starts
/// nothing. It runs no process, opens no socket and reads no credential, so
/// the suite still cannot reach a real `claude` or a real ollama.
struct ScriptedBackend {
    /// The bodies to emit for every send, in order.
    script: Vec<EventBody>,
    /// What the last `start` was handed, so a test can read the attachment
    /// directory the daemon gave the backend and the blocks it received.
    seen: Seen,
}

impl Backend for ScriptedBackend {
    fn id(&self) -> &'static str {
        CLAUDE_CODE
    }

    fn info(&self, _secrets: &SecretStore) -> BackendInfo {
        BackendInfo {
            id: CLAUDE_CODE.to_owned(),
            label: "Scripted".to_owned(),
            state: BackendState::Ready,
            models: Vec::new(),
            detail: None,
        }
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let (commands, mut inbox) = mpsc::unbounded_channel();
        let script = self.script.clone();
        let seen = Arc::clone(&self.seen);
        let attachments = ctx.attachments.clone();
        let sink = ctx.sink.clone();
        tokio::spawn(async move {
            while let Some(command) = inbox.recv().await {
                if let BackendCommand::Send { blocks } = command {
                    *seen.lock().expect("the recorder is not poisoned") =
                        Some((attachments.clone(), blocks));
                    for body in script.clone() {
                        sink.emit(body);
                    }
                }
            }
        });
        Ok(BackendHandle::new(commands))
    }
}

/// A registry holding one scripted backend under the `claude-code` id.
fn scripted(script: Vec<EventBody>) -> (Arc<Registry>, Seen) {
    let seen: Seen = Arc::new(Mutex::new(None));
    let backend = Arc::new(ScriptedBackend {
        script,
        seen: Arc::clone(&seen),
    });
    let policy = Policy::open(PathBuf::from("/nonexistent/dots-ask/policy.json"))
        .expect("a policy file that is not there loads as empty");
    let registry = Registry::new(
        vec![backend],
        Arc::new(SecretStore::default()),
        Arc::new(McpPool::empty()),
        Arc::new(Mutex::new(policy)),
    );
    (Arc::new(registry), seen)
}

/// The three bodies a turn that writes one HTML page produces.
fn html_turn(source: &str) -> Vec<EventBody> {
    vec![
        EventBody::TurnStart {
            turn: None,
            backend: CLAUDE_CODE.to_owned(),
            model: None,
            started_ms: 1,
        },
        EventBody::CodeBlock {
            turn: None,
            block: 0,
            language: Some("html".to_owned()),
            source: source.to_owned(),
            html: None,
        },
        EventBody::TurnEnd {
            turn: None,
            stop: StopReason::EndTurn,
            text: None,
            duration_ms: 1,
        },
    ]
}

#[tokio::test(flavor = "multi_thread")]
async fn an_html_fence_produces_an_artifact_beside_its_code_block() {
    // Beside, not instead of. The code block is the record of what the model
    // wrote, and a person should be able to read a page's source without
    // opening the page.
    let (registry, _seen) = scripted(html_turn("<html><body>hi</body></html>"));
    let harness = Harness::with_registry(registry).await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;
    client
        .send(&json!({"op": "send", "conversation": conversation,
                      "blocks": [{"kind": "text", "text": "make me a page"}]}))
        .await;

    client.expect_event("user_message").await;
    client.expect_event("turn_start").await;
    let code = client.expect_event("code_block").await;
    assert_eq!(code["language"], json!("html"));
    let artifact = client.expect_event("artifact").await;

    assert_eq!(artifact["conversation"], json!(conversation));
    assert_eq!(artifact["revision"], json!(1));
    assert_eq!(
        artifact["turn"], code["turn"],
        "same turn as its code block"
    );
    assert_eq!(
        artifact["seq"].as_u64().expect("seq"),
        code["seq"].as_u64().expect("seq") + 1,
        "the two are adjacent, so a replay brings them back together"
    );
    let path = PathBuf::from(artifact["path"].as_str().expect("path"));
    assert_eq!(
        fs::read_to_string(&path).expect("the page is on disk"),
        "<html><body>hi</body></html>",
        "the page is durable before the event announcing it goes out"
    );
    assert!(
        path.starts_with(harness.root.join("state").join("artifacts")),
        "artifacts live under the data root, beside the transcripts: {}",
        path.display()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_fence_that_is_not_html_produces_no_artifact() {
    // Markdown, code, SVG and images render in the pane. Only HTML leaves it.
    let script = vec![
        EventBody::TurnStart {
            turn: None,
            backend: CLAUDE_CODE.to_owned(),
            model: None,
            started_ms: 1,
        },
        EventBody::CodeBlock {
            turn: None,
            block: 0,
            language: Some("rust".to_owned()),
            source: "fn main() {}\n".to_owned(),
            html: None,
        },
        EventBody::TurnEnd {
            turn: None,
            stop: StopReason::EndTurn,
            text: None,
            duration_ms: 1,
        },
    ];
    let (registry, _seen) = scripted(script);
    let harness = Harness::with_registry(registry).await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;
    client
        .send(&json!({"op": "send", "conversation": conversation,
                      "blocks": [{"kind": "text", "text": "hi"}]}))
        .await;

    client.expect_event("user_message").await;
    client.expect_event("turn_start").await;
    client.expect_event("code_block").await;
    client.expect_event("turn_end").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_regenerated_page_keeps_its_id_and_raises_its_revision() {
    // What makes an already-open window reload rather than a second window
    // open: the id and the URL stand still and only the revision moves.
    let (registry, _seen) = scripted(html_turn("<p>version</p>"));
    let harness = Harness::with_registry(registry).await;
    let mut client = harness.client().await;
    client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;

    let mut seen = Vec::new();
    for _ in 0..2 {
        client
            .send(&json!({"op": "send", "conversation": conversation,
                          "blocks": [{"kind": "text", "text": "again"}]}))
            .await;
        client.expect_event("user_message").await;
        client.expect_event("turn_start").await;
        client.expect_event("code_block").await;
        seen.push(client.expect_event("artifact").await);
        client.expect_event("turn_end").await;
    }

    assert_eq!(
        seen[0]["artifact"], seen[1]["artifact"],
        "the id must not move"
    );
    assert_eq!(seen[0]["path"], seen[1]["path"], "the file must not move");
    assert_eq!(seen[0]["revision"], json!(1));
    assert_eq!(seen[1]["revision"], json!(2));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_attachment_is_copied_in_before_the_user_message_records_it() {
    // The path a transcript keeps has to outlive the pane's scratch, and it
    // has to be the one the backend was given, or the two disagree about
    // which bytes were sent.
    let (registry, seen) = scripted(Vec::new());
    let harness = Harness::with_registry(registry).await;
    let scratch = harness.root.join("cap-3.png");
    fs::write(&scratch, b"not really a png").expect("the capture writes");

    let mut client = harness.client().await;
    client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;
    client
        .send(
            &json!({"op": "send", "conversation": conversation, "blocks": [
            {"kind": "text", "text": "what is this"},
            {"kind": "image", "path": scratch, "mime": "image/png"}]}),
        )
        .await;

    let recorded = client.expect_event("user_message").await;
    let kept = PathBuf::from(
        recorded["blocks"][1]["path"]
            .as_str()
            .expect("the block keeps a path"),
    );
    assert_ne!(kept, scratch, "the transcript names the copy");
    assert!(
        kept.starts_with(harness.root.join("state").join("attachments")),
        "attachments live under the data root, beside the transcripts: {}",
        kept.display()
    );
    assert_eq!(
        fs::read(&kept).expect("the copy is there"),
        b"not really a png"
    );
    assert!(
        scratch.exists(),
        "the original is not the daemon's to delete"
    );

    // And the backend was handed the same rewritten block plus the directory
    // it sits in, which is what the harness turns into one --add-dir.
    let (attachments, blocks) = loop {
        if let Some(seen) = seen.lock().expect("the recorder is not poisoned").clone() {
            break seen;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    };
    assert_eq!(blocks[1].path.as_deref(), Some(kept.as_path()));
    assert!(kept.starts_with(&attachments), "{}", attachments.display());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_naming_a_file_that_is_not_there_is_refused_and_records_nothing() {
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    let (_, before) = client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;
    client
        .send(
            &json!({"op": "send", "conversation": conversation, "blocks": [
            {"kind": "image", "path": "/nowhere/at/all.png", "mime": "image/png"}]}),
        )
        .await;

    let error = client.expect_event("error").await;
    assert_eq!(error["kind"], json!("bad_request"));
    assert_eq!(
        error["seq"],
        Value::Null,
        "bad_request is connection-scoped"
    );
    assert!(
        error["message"]
            .as_str()
            .expect("message")
            .contains("/nowhere/at/all.png"),
        "{error}"
    );

    // Nothing was persisted, so a reconnect replays no half-message.
    let mut second = harness.client().await;
    let (replay, seq_head) = second.hello(Some(before)).await;
    assert!(
        replay
            .iter()
            .all(|event| event["event"] != json!("user_message")),
        "a refused send must leave no user_message: {replay:?}"
    );
    assert_eq!(seq_head, before, "a refused send spends no seq");
}

#[tokio::test(flavor = "multi_thread")]
async fn deleting_a_thread_takes_its_pages_and_its_attachments() {
    let (registry, _seen) = scripted(html_turn("<p>gone</p>"));
    let harness = Harness::with_registry(registry).await;
    let scratch = harness.root.join("cap.png");
    fs::write(&scratch, b"bytes").expect("the capture writes");

    let mut client = harness.client().await;
    client.hello(None).await;
    let conversation = Uuid::new_v4();
    client.new_thread(conversation).await;
    client
        .send(
            &json!({"op": "send", "conversation": conversation, "blocks": [
            {"kind": "image", "path": scratch, "mime": "image/png"}]}),
        )
        .await;

    let recorded = client.expect_event("user_message").await;
    let attachment = PathBuf::from(recorded["blocks"][0]["path"].as_str().expect("path"));
    client.expect_event("turn_start").await;
    client.expect_event("code_block").await;
    let artifact = client.expect_event("artifact").await;
    let page = PathBuf::from(artifact["path"].as_str().expect("path"));
    client.expect_event("turn_end").await;
    assert!(attachment.exists() && page.exists());

    client
        .send(&json!({"op": "delete", "conversation": conversation}))
        .await;
    client.expect_event("conversations").await;

    assert!(
        !attachment.exists(),
        "a deleted thread keeps no attachments"
    );
    assert!(!page.exists(), "a deleted thread keeps no pages");
}

#[tokio::test(flavor = "multi_thread")]
async fn ready_carries_an_artifact_base_key_that_is_null_with_no_server() {
    // The port lives on an ephemeral reply and never in a transcript, so a
    // daemon with no loopback listener says null rather than a dead URL.
    let harness = Harness::start().await;
    let mut client = harness.client().await;
    client
        .send(&json!({"op": "hello", "protocol": 1, "resume_seq": null}))
        .await;
    let ready = client.expect_event("ready").await;
    assert!(
        ready.get("artifact_base").is_some(),
        "the key is always there: {ready}"
    );
    assert_eq!(ready["artifact_base"], Value::Null);
}
