//! Drives the real provider turn loop and the approval gate in front of it.
//!
//! Everything `provider.rs` does between "a user said something" and "the
//! turn ended" runs here: `run_turn`, `stream_once`, `run_tools`, `approve`,
//! `wait_for`, `invoke` and `locate`. Those are the lines that decide what
//! may execute, so leaving them compiled and unexecuted was how a broken
//! conversation history shipped.
//!
//! ## Why there is a socket in here
//!
//! The brief says no network in any test, and there is none: the fake
//! provider is a `TcpListener` this file binds on `127.0.0.1:0`, answers from
//! a script the test wrote, and drops at the end. Nothing resolves a name,
//! nothing leaves the host, and the bytes it replays are the same recorded
//! fixtures the decoder tests use. It exists because the turn loop's bug was
//! in *what it sends*, and the only way to assert on a request body is to be
//! the thing that receives it.
//!
//! ## The property these tests exist for
//!
//! A provider is stateless. Everything the model knows about the
//! conversation is in the array the daemon posts, so every round has to carry
//! what the assistant said and what its tools returned. Miss the assistant
//! message and two things break at once: the model forgets its own replies,
//! and a `tool_result` arrives with no `tool_use` in front of it, which the
//! Messages API and OpenAI both reject with a 400.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use uuid::Uuid;

use ask_daemon::backend::ollama::OllamaDecoder;
use ask_daemon::backend::provider::{PendingToolCall, ProviderSession, TurnRequest};
use ask_daemon::backend::{BackendCommand, BackendContext, BackendMessage, EventSink};
use ask_daemon::mcp::{McpPool, McpTool};
use ask_daemon::policy::Policy;
use ask_daemon::proto::{
    ErrorKind, EventBody, PermissionDecision, PermissionScope, SendBlock, StopReason,
};
use ask_daemon::secrets::SecretStore;

/// A recorded plain answer, used as a round's response.
const PROSE: &str = include_str!("fixtures/ollama-ndjson.txt");

/// A recorded answer that asks for a tool.
const TOOLS: &str = include_str!("fixtures/ollama-tools-ndjson.txt");

/// How long a test waits for the turn loop to reach a step.
const PATIENCE: Duration = Duration::from_secs(20);

// -- the fake provider -----------------------------------------------------

/// A provider that answers from a script and remembers what it was asked.
///
/// One connection per request, `Content-Length` framed, HTTP/1.1. `reqwest`
/// speaks 1.1 to an `http://` origin unless told otherwise, so no TLS and no
/// h2 negotiation are involved.
struct FakeProvider {
    addr: SocketAddr,
    /// The JSON body of each request, in the order they arrived.
    seen: Arc<Mutex<Vec<Value>>>,
}

impl FakeProvider {
    /// Serve `script` in order, one entry per request.
    ///
    /// A request past the end of the script gets the last entry again, so a
    /// test that only cares about the first two rounds does not have to
    /// predict how many the loop will make.
    async fn start(script: Vec<String>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("a loopback port is available");
        let addr = listener.local_addr().expect("the socket has an address");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorder = Arc::clone(&seen);

        tokio::spawn(async move {
            let mut answered = 0_usize;
            while let Ok((mut stream, _)) = listener.accept().await {
                let Some(body) = read_request(&mut stream).await else {
                    continue;
                };
                if let Ok(mut seen) = recorder.lock() {
                    seen.push(body);
                }
                let reply = script
                    .get(answered)
                    .or_else(|| script.last())
                    .cloned()
                    .unwrap_or_default();
                answered += 1;
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    reply.len()
                );
                let _ = stream.write_all(head.as_bytes()).await;
                let _ = stream.write_all(reply.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });

        Self { addr, seen }
    }

    /// Where to point a `TurnRequest`.
    fn url(&self) -> String {
        format!("http://{}/v1/chat", self.addr)
    }

    /// The request bodies this provider received.
    fn requests(&self) -> Vec<Value> {
        self.seen
            .lock()
            .expect("the recorder is not poisoned")
            .clone()
    }

    /// The `messages` array of one request, by index.
    fn messages(&self, round: usize) -> Vec<Value> {
        let requests = self.requests();
        let body = requests
            .get(round)
            .unwrap_or_else(|| panic!("round {round} was never requested; got {}", requests.len()));
        body["messages"]
            .as_array()
            .expect("every request carries a messages array")
            .clone()
    }
}

/// Read one HTTP request and return its JSON body.
async fn read_request(stream: &mut tokio::net::TcpStream) -> Option<Value> {
    let mut raw = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let read = stream.read(&mut buffer).await.ok()?;
        if read == 0 {
            break;
        }
        raw.extend_from_slice(&buffer[..read]);
        let text = String::from_utf8_lossy(&raw);
        let Some(head_end) = text.find("\r\n\r\n") else {
            continue;
        };
        let length: usize = text[..head_end]
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse().ok())?
            })
            .unwrap_or(0);
        if raw.len() >= head_end + 4 + length {
            return serde_json::from_slice(&raw[head_end + 4..head_end + 4 + length]).ok();
        }
    }
    None
}

// -- the session under test ------------------------------------------------

/// Everything one test needs to drive a turn.
///
/// The event receiver lives in a task started once and never moved, because
/// the turn loop reads the same command channel a decision arrives on: a
/// caller blocked on `run_turn` cannot also answer the prompt `run_turn` is
/// waiting for. So a watcher owns the events for the harness's whole life,
/// records them, and answers any permission request from a cell the test
/// sets before each turn.
struct Harness {
    session: ProviderSession,
    commands: mpsc::UnboundedSender<BackendCommand>,
    inbox: mpsc::UnboundedReceiver<BackendCommand>,
    seen: Arc<Mutex<Vec<EventBody>>>,
    decision: Arc<Mutex<PermissionDecision>>,
    policy: Arc<Mutex<Policy>>,
    /// Removed on drop.
    root: PathBuf,
}

impl Harness {
    /// A session with no MCP server configured, so no tool exists.
    fn new() -> Self {
        Self::with_pool(McpPool::empty())
    }

    /// A session that knows about `searxng__web_search` but has no server
    /// running behind it.
    ///
    /// That is the pool the approval gate needs: the name resolves, so the
    /// gate runs and prompts, and the call afterwards fails on the missing
    /// server rather than on the missing name. Standing up a real MCP server
    /// in a test would prove nothing more about the gate.
    fn with_a_known_tool() -> Self {
        Self::with_pool(McpPool::with_tools(
            BTreeMap::new(),
            vec![McpTool {
                server: "searxng".to_owned(),
                name: "web_search".to_owned(),
                description: Some("search the web".to_owned()),
                input_schema: json!({"type": "object"}),
            }],
        ))
    }

    /// A session for one thread over the pool given.
    fn with_pool(mcp: McpPool) -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-provider-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("temp root is creatable");
        let policy = Arc::new(Mutex::new(
            Policy::open(root.join("policy.json")).expect("an absent policy file loads empty"),
        ));
        let (sender, events) = mpsc::unbounded_channel();
        let context = BackendContext {
            conversation: Uuid::new_v4(),
            model: Some("ornith:9b".to_owned()),
            cwd: root.clone(),
            sink: EventSink::new(Uuid::new_v4(), sender),
            secrets: Arc::new(SecretStore::default()),
            mcp: Arc::new(mcp),
            policy: Arc::clone(&policy),
        };
        let session = ProviderSession::new(&context, "ollama");
        let (commands, inbox) = mpsc::unbounded_channel();

        let seen = Arc::new(Mutex::new(Vec::new()));
        let decision = Arc::new(Mutex::new(PermissionDecision::Deny));
        tokio::spawn(watch(
            events,
            commands.clone(),
            Arc::clone(&seen),
            Arc::clone(&decision),
        ));

        Self {
            session,
            commands,
            inbox,
            seen,
            decision,
            policy,
            root,
        }
    }

    /// Run one turn against `provider`, answering any permission request with
    /// `decision`.
    async fn turn(&mut self, provider: &FakeProvider, text: &str, decision: PermissionDecision) {
        *self.decision.lock().expect("the cell is not poisoned") = decision;
        self.session.push_user(&[text_block(text)]);
        let request =
            ask_daemon::backend::ollama::request(&provider.url(), "ornith:9b", Vec::new());
        self.run(&request).await;
    }

    /// Run one turn against an already-built request.
    ///
    /// `run_turn` returns as soon as it has queued the `turn_end`, which is
    /// before the watcher has taken it off the channel, so this waits for the
    /// close to be recorded. Without that a test reads a snapshot of the
    /// events that is one task-poll short of the truth.
    async fn run(&mut self, request: &TurnRequest) {
        let closed_before = self.closes();
        let alive = tokio::time::timeout(
            PATIENCE,
            self.session
                .run_turn::<OllamaDecoder>(Some("ornith:9b"), request, &mut self.inbox),
        )
        .await
        .expect("the turn finished inside the deadline");
        assert!(alive, "the daemon stayed attached");

        let deadline = tokio::time::Instant::now() + PATIENCE;
        while self.closes() == closed_before {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the watcher never recorded the turn closing: {:#?}",
                self.drained()
            );
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }

    /// How many turns have closed so far.
    fn closes(&self) -> usize {
        self.drained()
            .iter()
            .filter(|body| matches!(body, EventBody::TurnEnd { .. }))
            .count()
    }

    /// Every event the harness has seen so far.
    fn drained(&self) -> Vec<EventBody> {
        self.seen
            .lock()
            .expect("the recorder is not poisoned")
            .clone()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        drop(std::fs::remove_dir_all(&self.root));
    }
}

/// Record every event and answer any permission request.
async fn watch(
    mut events: mpsc::UnboundedReceiver<BackendMessage>,
    commands: mpsc::UnboundedSender<BackendCommand>,
    seen: Arc<Mutex<Vec<EventBody>>>,
    decision: Arc<Mutex<PermissionDecision>>,
) {
    while let Some(message) = events.recv().await {
        if let EventBody::PermissionRequest {
            request, withdrawn, ..
        } = &message.body
        {
            if !withdrawn {
                let verdict = *decision.lock().expect("the cell is not poisoned");
                let _ = commands.send(BackendCommand::Permission {
                    request: request.clone(),
                    decision: verdict,
                    scope: PermissionScope::Once,
                    updated_input: None,
                    message: Some("refused by the test".to_owned()),
                });
            }
        }
        if let Ok(mut seen) = seen.lock() {
            seen.push(message.body);
        }
    }
}

/// One text block for a `send`.
fn text_block(text: &str) -> SendBlock {
    SendBlock {
        kind: ask_daemon::proto::BlockKind::Text,
        text: Some(text.to_owned()),
        path: None,
        mime: None,
    }
}

/// The `role` of each message in a history.
fn roles(messages: &[Value]) -> Vec<&str> {
    messages
        .iter()
        .map(|message| message["role"].as_str().unwrap_or("<none>"))
        .collect()
}

// -- the history, which is what shipped broken ----------------------------

#[tokio::test]
async fn a_follow_up_turn_carries_what_the_assistant_already_said() {
    // A provider is stateless: everything the model knows is in the array the
    // daemon posts. Without the assistant's own reply in it, every follow-up
    // is a fresh conversation wearing the last question's clothes.
    let provider = FakeProvider::start(vec![PROSE.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::new();

    harness
        .turn(&provider, "first question", PermissionDecision::Allow)
        .await;
    harness
        .turn(&provider, "second question", PermissionDecision::Allow)
        .await;

    let second = provider.messages(1);
    assert_eq!(
        roles(&second),
        vec!["user", "assistant", "user"],
        "the second request must carry the first answer: {second:#?}"
    );
    let reply = second[1]["content"].as_str().unwrap_or_default();
    assert!(
        reply.contains("A unix socket"),
        "the assistant message is the text the first turn produced, got {reply:?}"
    );
}

#[tokio::test]
async fn a_tool_result_never_travels_without_the_call_that_produced_it() {
    // The Messages API rejects an orphan tool_result with a 400 and OpenAI
    // rejects a role:"tool" that follows no tool_calls, so a history that
    // omits the assistant block kills the second round of every tool turn.
    let provider = FakeProvider::start(vec![TOOLS.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::new();

    harness
        .turn(&provider, "search for something", PermissionDecision::Allow)
        .await;

    let second = provider.messages(1);
    assert_eq!(
        roles(&second),
        vec!["user", "assistant", "tool"],
        "the tool result must follow the assistant message that asked: {second:#?}"
    );
    let calls = second[1]["tool_calls"]
        .as_array()
        .expect("the assistant message carries the call it made");
    assert_eq!(calls.len(), 1, "one call was asked for: {calls:#?}");
    assert_eq!(
        calls[0]["function"]["name"], "searxng__web_search",
        "and it names the tool the model asked for"
    );
}

#[tokio::test]
async fn a_turn_that_asked_for_nothing_still_records_its_answer() {
    let provider = FakeProvider::start(vec![PROSE.to_owned()]).await;
    let mut harness = Harness::new();
    harness
        .turn(&provider, "hello", PermissionDecision::Allow)
        .await;

    let history = harness.session.messages();
    assert_eq!(
        roles(history),
        vec!["user", "assistant"],
        "the answer joins the history even when no tool was involved: {history:#?}"
    );
}

#[tokio::test]
async fn the_first_request_carries_only_the_question() {
    let provider = FakeProvider::start(vec![PROSE.to_owned()]).await;
    let mut harness = Harness::new();
    harness
        .turn(&provider, "hello", PermissionDecision::Allow)
        .await;

    assert_eq!(
        roles(&provider.messages(0)),
        vec!["user"],
        "nothing is invented before the model has spoken"
    );
}

// -- the approval gate -----------------------------------------------------

#[tokio::test]
async fn a_tool_call_is_denied_by_default_and_asks_first() {
    // Nothing in the policy store decides this call, so the daemon must ask
    // rather than assume, and the pane's answer is what settles it.
    let provider = FakeProvider::start(vec![TOOLS.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::with_a_known_tool();
    harness
        .turn(&provider, "search for something", PermissionDecision::Deny)
        .await;

    let events = harness.drained();
    let asked = events
        .iter()
        .filter(|body| matches!(body, EventBody::PermissionRequest { .. }))
        .count();
    assert_eq!(asked, 1, "one call, one prompt: {events:#?}");

    let [EventBody::ToolResult { ok, content, .. }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::ToolResult { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one tool result: {events:#?}");
    };
    assert!(!ok, "a denied call did not run");
    assert_eq!(
        content, "refused by the test",
        "the model is told what the person said"
    );
}

#[tokio::test]
async fn a_tool_nobody_configured_is_refused_without_a_prompt() {
    // Section 5's narrowest promise: v1 ships no built-in shell tool and no
    // built-in file tool, so a name no configured server exposes can never
    // execute whatever anybody answers. Asking about it would put a dialog in
    // front of a person whose only correct answer is no, so existence is
    // settled before permission and no prompt is raised at all.
    let provider = FakeProvider::start(vec![TOOLS.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::new();
    harness
        .turn(&provider, "search for something", PermissionDecision::Allow)
        .await;

    let events = harness.drained();
    assert!(
        !events
            .iter()
            .any(|body| matches!(body, EventBody::PermissionRequest { .. })),
        "nothing may be asked about a call that cannot run: {events:#?}"
    );

    let [EventBody::ToolResult { ok, content, .. }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::ToolResult { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one tool result: {events:#?}");
    };
    assert!(!ok, "a call with nothing behind it fails");
    assert!(
        content.contains("no configured MCP server"),
        "and says why rather than pretending it ran: {content}"
    );
    assert!(
        content.contains("built-in"),
        "naming the rule, so the message is actionable: {content}"
    );
}

#[tokio::test]
async fn the_tool_call_reaches_the_pane_before_the_prompt_does() {
    // The pane draws the call and then the approval on top of it, so a
    // prompt arriving first would have nothing to attach to.
    let provider = FakeProvider::start(vec![TOOLS.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::with_a_known_tool();
    harness
        .turn(&provider, "search for something", PermissionDecision::Deny)
        .await;

    let events = harness.drained();
    let order: Vec<&str> = events
        .iter()
        .filter_map(|body| match body {
            EventBody::ToolCall { .. } => Some("tool_call"),
            EventBody::PermissionRequest { .. } => Some("permission_request"),
            EventBody::ToolResult { .. } => Some("tool_result"),
            _ => None,
        })
        .collect();
    assert_eq!(
        order,
        vec!["tool_call", "permission_request", "tool_result"],
        "{events:#?}"
    );
}

#[tokio::test]
async fn a_denied_call_is_not_remembered_as_a_standing_rule() {
    // The test answers with scope Once, so nothing may reach the store.
    let provider = FakeProvider::start(vec![TOOLS.to_owned(), PROSE.to_owned()]).await;
    let mut harness = Harness::with_a_known_tool();
    harness
        .turn(&provider, "search for something", PermissionDecision::Deny)
        .await;

    let forever = harness
        .policy
        .lock()
        .expect("the policy is not poisoned")
        .forever_len();
    assert_eq!(forever, 0, "a once decision writes no rule");
}

// -- the turn's own events -------------------------------------------------

#[tokio::test]
async fn a_plain_turn_opens_and_closes_exactly_once() {
    let provider = FakeProvider::start(vec![PROSE.to_owned()]).await;
    let mut harness = Harness::new();
    harness
        .turn(&provider, "hello", PermissionDecision::Allow)
        .await;

    let events = harness.drained();
    assert_eq!(
        events
            .iter()
            .filter(|body| matches!(body, EventBody::TurnStart { .. }))
            .count(),
        1
    );
    let [EventBody::TurnEnd { stop, text, .. }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::TurnEnd { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one turn_end: {events:#?}");
    };
    assert_eq!(*stop, StopReason::EndTurn);
    assert!(
        text.as_deref()
            .is_some_and(|text| text.contains("A unix socket")),
        "the summary is what the model actually said: {text:?}"
    );
}

#[tokio::test]
async fn a_provider_that_answers_with_an_error_status_ends_the_turn() {
    // A 401 is the shape a wrong credential takes, and section 2 gives that
    // its own error kind so the pane can say "check the key" rather than
    // "something went wrong".
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("a loopback port is available");
    let addr = listener.local_addr().expect("the socket has an address");
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut scratch = [0_u8; 4096];
            let _ = stream.read(&mut scratch).await;
            let body = "{\"error\":{\"message\":\"invalid x-api-key\"}}";
            let head = format!(
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes()).await;
            let _ = stream.write_all(body.as_bytes()).await;
            let _ = stream.shutdown().await;
        }
    });

    let mut harness = Harness::new();
    harness.session.push_user(&[text_block("hello")]);
    let request =
        ask_daemon::backend::ollama::request(&format!("http://{addr}/v1/chat"), "m", Vec::new());
    harness.run(&request).await;

    let events = harness.drained();
    let [EventBody::Error { kind, message, .. }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::Error { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one error: {events:#?}");
    };
    assert_eq!(*kind, ErrorKind::Auth, "401 is a credential problem");
    assert!(
        message.contains("invalid x-api-key"),
        "the provider's own words reach the pane: {message}"
    );
    assert!(
        events
            .iter()
            .any(|body| matches!(body, EventBody::TurnEnd { .. })),
        "a failed turn still closes: {events:#?}"
    );
}

#[tokio::test]
async fn an_interrupt_stops_the_turn_and_raises_no_error() {
    let provider = FakeProvider::start(vec![PROSE.to_owned()]).await;
    let mut harness = Harness::new();
    harness.session.push_user(&[text_block("hello")]);
    let request = ask_daemon::backend::ollama::request(&provider.url(), "ornith:9b", Vec::new());

    harness
        .commands
        .send(BackendCommand::Interrupt)
        .expect("the inbox is open");
    harness.run(&request).await;

    let events = harness.drained();
    let [EventBody::TurnEnd { stop, text, .. }] = events
        .iter()
        .filter(|body| matches!(body, EventBody::TurnEnd { .. }))
        .collect::<Vec<_>>()[..]
    else {
        panic!("expected exactly one turn_end: {events:#?}");
    };
    assert_eq!(*stop, StopReason::Interrupted);
    assert_eq!(*text, None, "an interrupted turn sends no summary");
    assert!(
        !events
            .iter()
            .any(|body| matches!(body, EventBody::Error { .. })),
        "the client asked for this, so it is not a failure: {events:#?}"
    );
}

// -- the shapes each provider builds --------------------------------------

#[test]
fn the_body_a_provider_posts_is_built_from_the_history_it_is_given() {
    let request = ask_daemon::backend::ollama::request("http://127.0.0.1:1/x", "m", Vec::new());
    let history = vec![json!({"role": "user", "content": "hi"})];
    let body = request.body(&history);
    assert_eq!(body["model"], "m");
    assert_eq!(body["stream"], true);
    assert_eq!(body["messages"], json!(history));
}

#[test]
fn a_tool_schema_list_reaches_the_request_and_an_empty_one_does_not() {
    let bare = ask_daemon::backend::ollama::request("http://127.0.0.1:1/x", "m", Vec::new());
    assert_eq!(
        bare.body(&[]).get("tools"),
        None,
        "a model with no tools must not be told it has an empty set"
    );

    let schema = json!({"type": "function", "function": {"name": "t", "parameters": {}}});
    let armed =
        ask_daemon::backend::ollama::request("http://127.0.0.1:1/x", "m", vec![schema.clone()]);
    assert_eq!(armed.body(&[])["tools"], json!([schema]));
}

#[test]
fn the_anthropic_request_carries_the_credential_and_the_api_version() {
    let request =
        ask_daemon::backend::anthropic::request("http://127.0.0.1:1/x", "sk-test", "m", Vec::new());
    let headers: BTreeMap<&str, &str> = request
        .headers
        .iter()
        .map(|(name, value)| (name.as_str(), value.as_str()))
        .collect();
    assert_eq!(headers.get("x-api-key"), Some(&"sk-test"));
    assert!(
        headers.contains_key("anthropic-version"),
        "the Messages API refuses a request without it: {headers:?}"
    );
    assert!(
        request.body(&[]).get("max_tokens").is_some(),
        "and refuses one without max_tokens"
    );
}

/// One tool call the way a decoder hands it over.
fn pending_call() -> PendingToolCall {
    PendingToolCall {
        id: "toolu_01Xyz".to_owned(),
        name: "searxng__web_search".to_owned(),
        arguments: "{\"query\":\"unix socket\"}".to_owned(),
    }
}

#[test]
fn the_anthropic_assistant_message_carries_the_id_its_tool_result_will_name() {
    // The Messages API matches a tool_result to its tool_use by id, and
    // answers 400 when it cannot. This is the pairing, in one assertion.
    let request =
        ask_daemon::backend::anthropic::request("http://127.0.0.1:1/x", "k", "m", Vec::new());
    let call = pending_call();
    let assistant = (request.record_assistant)("on it", std::slice::from_ref(&call))
        .expect("a turn with text and a call records a message");
    assert_eq!(assistant["role"], "assistant");

    let content = assistant["content"]
        .as_array()
        .expect("the Messages API takes a block list");
    assert_eq!(content[0]["type"], "text");
    assert_eq!(content[0]["text"], "on it");
    assert_eq!(content[1]["type"], "tool_use");
    assert_eq!(content[1]["id"], "toolu_01Xyz");
    assert_eq!(content[1]["name"], "searxng__web_search");
    assert_eq!(content[1]["input"], json!({"query": "unix socket"}));

    let result = (request.record_result)(&call, true, "found it");
    assert_eq!(
        result["content"][0]["tool_use_id"], content[1]["id"],
        "the result names the call the assistant message announced"
    );
}

#[test]
fn a_tool_only_anthropic_turn_records_no_empty_text_block() {
    // An empty text block is itself a 400.
    let request =
        ask_daemon::backend::anthropic::request("http://127.0.0.1:1/x", "k", "m", Vec::new());
    let assistant = (request.record_assistant)("", &[pending_call()])
        .expect("a call with no prose still records");
    let content = assistant["content"].as_array().expect("a block list");
    assert_eq!(content.len(), 1, "only the call: {content:#?}");
    assert_eq!(content[0]["type"], "tool_use");
}

#[test]
fn a_round_that_produced_nothing_records_nothing() {
    // The failed-request case. An assistant message with neither text nor a
    // call is rejected by every provider here, so none is written.
    for request in [
        ask_daemon::backend::anthropic::request("http://127.0.0.1:1/x", "k", "m", Vec::new()),
        ask_daemon::backend::openai::request("http://127.0.0.1:1/x", "k", "m", Vec::new()),
        ask_daemon::backend::ollama::request("http://127.0.0.1:1/x", "m", Vec::new()),
    ] {
        assert!(
            (request.record_assistant)("", &[]).is_none(),
            "an empty turn must not append an empty message"
        );
    }
}

#[test]
fn the_openai_assistant_message_carries_the_id_its_tool_message_will_name() {
    let request =
        ask_daemon::backend::openai::request("http://127.0.0.1:1/x", "k", "m", Vec::new());
    let call = pending_call();
    let assistant = (request.record_assistant)("", std::slice::from_ref(&call))
        .expect("a call records a message");
    assert_eq!(assistant["role"], "assistant");
    assert_eq!(
        assistant["content"],
        Value::Null,
        "content is null on a tool-only turn, which is the documented shape"
    );

    let calls = assistant["tool_calls"].as_array().expect("a call list");
    assert_eq!(calls[0]["id"], "toolu_01Xyz");
    assert_eq!(calls[0]["type"], "function");
    assert_eq!(calls[0]["function"]["name"], "searxng__web_search");
    assert_eq!(
        calls[0]["function"]["arguments"], "{\"query\":\"unix socket\"}",
        "the arguments go back as the text the server streamed, not re-serialized"
    );

    let result = (request.record_result)(&call, true, "found it");
    assert_eq!(result["role"], "tool");
    assert_eq!(
        result["tool_call_id"], calls[0]["id"],
        "an orphan role:\"tool\" is a 400, so the ids have to match"
    );
}

#[test]
fn the_ollama_assistant_message_sends_arguments_back_as_an_object() {
    // ollama streams the arguments as an object and takes them back the same
    // way, unlike the two OpenAI-shaped families.
    let request = ask_daemon::backend::ollama::request("http://127.0.0.1:1/x", "m", Vec::new());
    let assistant =
        (request.record_assistant)("sure", &[pending_call()]).expect("a call records a message");
    assert_eq!(assistant["content"], "sure");
    assert_eq!(
        assistant["tool_calls"][0]["function"]["arguments"],
        json!({"query": "unix socket"})
    );
}

#[test]
fn the_openai_request_asks_for_the_usage_it_would_otherwise_never_get() {
    let request =
        ask_daemon::backend::openai::request("http://127.0.0.1:1/x", "sk-test", "m", Vec::new());
    let body = request.body(&[]);
    assert_eq!(
        body["stream_options"]["include_usage"],
        json!(true),
        "a streamed completion reports no counts unless the request asks"
    );
    let headers: Vec<&str> = request
        .headers
        .iter()
        .map(|(name, _)| name.as_str())
        .collect();
    assert!(headers.contains(&"authorization"), "{headers:?}");
}
