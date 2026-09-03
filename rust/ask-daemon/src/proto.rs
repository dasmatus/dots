//! The normalized event schema, both directions, exactly as
//! `docs/superpowers/specs/2026-09-03-ask-pane-design.md` section 2 freezes
//! it. Protocol version 1.
//!
//! Framing is one JSON object per line, the rule
//! `rust/settings-global/src/rpc.rs` already states for the settings
//! sidecar. Quickshell reads it with `Socket` plus `SplitParser`, so a
//! multi-line object would be read as several broken frames.
//!
//! Two invariants live here rather than in the server, because a decoder on
//! the QML side depends on both.
//!
//! A daemon event is either persisted or ephemeral, and its own tag decides
//! which. Persisted conversation events take the next value of one
//! daemon-wide `u64` and carry a real conversation. Ephemeral replies answer
//! one connection, are never stored, and carry `seq: null` and
//! `conversation: null`. That split is what keeps the persisted `seq` space
//! dense, which is what makes replay from `resume_seq` gap-free. `EventBody::
//! scope` is the single place that mapping is written down.
//!
//! Value sets the spec enumerates in full are Rust enums, not strings. The
//! wire bytes are identical, but the daemon then cannot invent a `stop`
//! reason the pane has no branch for, and a match on `ErrorKind` cannot
//! forget one of the seven kinds.

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

/// The protocol version this build speaks, sent in `ready` and expected in
/// `hello`.
pub const PROTOCOL_VERSION: u32 = 1;

/// The `limit` a `list` frame takes when it omits one.
const DEFAULT_LIST_LIMIT: u32 = 50;

/// `serde` default for [`ClientFrame::List::limit`].
fn default_list_limit() -> u32 {
    DEFAULT_LIST_LIMIT
}

// -- client to daemon ------------------------------------------------------

/// One frame a client sends, tagged by `op`.
///
/// Every op except `hello` and `list` names a conversation. An `op` this
/// enum does not have fails to deserialize, and the server answers with a
/// connection-scoped `error` carrying [`ErrorKind::BadRequest`] rather than
/// closing the connection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientFrame {
    /// Attach to the daemon and resume. `resume_seq` is the highest `seq`
    /// the client already rendered, or `None` on a cold start. This is the
    /// only automatic replay the daemon performs.
    Hello {
        /// The protocol version the client speaks.
        protocol: u32,
        /// Highest `seq` the client already holds, across every conversation.
        #[serde(default)]
        resume_seq: Option<u64>,
    },
    /// Ask for conversation metadata, answered with a `conversations` event.
    List {
        /// How many threads to return at most.
        #[serde(default = "default_list_limit")]
        limit: u32,
        /// An `updated_ms` cursor for paging; only older threads come back.
        #[serde(default)]
        before: Option<u64>,
    },
    /// Subscribe to one conversation from a point the client names.
    ///
    /// This never re-sends what the client already holds: `from_seq` is the
    /// highest `seq` the client has for that thread and the daemon sends
    /// strictly greater ones. `None` means the client holds nothing.
    Open {
        /// The thread to open.
        conversation: Uuid,
        /// Highest `seq` the client holds for this thread.
        #[serde(default)]
        from_seq: Option<u64>,
    },
    /// Create a thread. The client mints the id so it can address the thread
    /// before the daemon has answered.
    New {
        /// The client-minted thread id.
        conversation: Uuid,
        /// One of the ids the last `backends` event listed.
        backend: String,
        /// `None` means the backend's own default.
        #[serde(default)]
        model: Option<String>,
        /// The working directory the harness gets through `--add-dir`.
        cwd: PathBuf,
        /// `None` until the first turn names the thread.
        #[serde(default)]
        title: Option<String>,
    },
    /// Send one user message. Attachments travel as paths, never inline
    /// base64.
    Send {
        /// The thread to send into.
        conversation: Uuid,
        /// The message body, in order.
        blocks: Vec<SendBlock>,
    },
    /// Stop the running turn. The turn ends with `stop: "interrupted"` and
    /// no `error`, because the client asked for this.
    Interrupt {
        /// The thread whose turn to stop.
        conversation: Uuid,
    },
    /// Answer an open `permission_request`.
    Permission {
        /// The thread the request belongs to.
        conversation: Uuid,
        /// The backend's own request id, echoed from `permission_request`.
        request: String,
        /// Allow or deny.
        decision: PermissionDecision,
        /// How long the decision lasts.
        scope: PermissionScope,
        /// Replacement tool arguments when the user edited them.
        #[serde(default)]
        updated_input: Option<Value>,
        /// The reason text sent back on a denial.
        #[serde(default)]
        message: Option<String>,
    },
    /// Remove the thread and its stored events, answered with a fresh
    /// `conversations` event.
    Delete {
        /// The thread to remove.
        conversation: Uuid,
    },
}

impl ClientFrame {
    /// The thread this frame names, or `None` for `hello` and `list`.
    #[must_use]
    pub fn conversation(&self) -> Option<Uuid> {
        match self {
            Self::Hello { .. } | Self::List { .. } => None,
            Self::Open { conversation, .. }
            | Self::New { conversation, .. }
            | Self::Send { conversation, .. }
            | Self::Interrupt { conversation, .. }
            | Self::Permission { conversation, .. }
            | Self::Delete { conversation, .. } => Some(*conversation),
        }
    }
}

/// One block of a `send` message.
///
/// The spec types `text`, `path` and `mime` as optional on every block and
/// puts the requirement on `kind` instead, so this is a flat struct rather
/// than a tagged enum. [`SendBlock::validate`] is where the requirement is
/// actually enforced.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SendBlock {
    /// What the block carries.
    pub kind: BlockKind,
    /// Required when `kind` is `text`.
    #[serde(default)]
    pub text: Option<String>,
    /// Required when `kind` is `image` or `file`.
    #[serde(default)]
    pub path: Option<PathBuf>,
    /// The block's media type, when the client knows one.
    #[serde(default)]
    pub mime: Option<String>,
}

impl SendBlock {
    /// Check that the block carries the field its `kind` requires.
    ///
    /// # Errors
    ///
    /// Returns the message for a connection-scoped
    /// [`ErrorKind::BadRequest`] when a text block has no `text` or an
    /// attachment block has no `path`.
    pub fn validate(&self) -> Result<(), String> {
        match self.kind {
            BlockKind::Text if self.text.is_none() => {
                Err("send block of kind \"text\" carries no text".to_owned())
            }
            BlockKind::Image | BlockKind::File if self.path.is_none() => {
                Err(format!("send block of kind {} carries no path", self.kind))
            }
            _ => Ok(()),
        }
    }
}

/// What a [`SendBlock`] carries.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockKind {
    /// Prose typed by the user.
    Text,
    /// An image on disk, referenced by path.
    Image,
    /// Any other file on disk, referenced by path.
    File,
}

impl fmt::Display for BlockKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = match self {
            Self::Text => "\"text\"",
            Self::Image => "\"image\"",
            Self::File => "\"file\"",
        };
        f.write_str(name)
    }
}

/// The verdict on a permission request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionDecision {
    /// Run the tool.
    Allow,
    /// Refuse the tool and hand the model the `message` text.
    Deny,
}

/// How long a permission decision lasts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionScope {
    /// This call only.
    Once,
    /// Until the conversation or the daemon ends.
    Session,
    /// Written to `policy.json`; the only scope that reaches disk.
    Forever,
}

// -- daemon to client ------------------------------------------------------

/// One frame the daemon sends.
///
/// `seq` and `conversation` sit outside the tagged body because every event
/// carries them, and because their nullability is decided by
/// [`EventBody::scope`] rather than by the variant's own fields. Build one
/// with [`ServerEvent::persisted`] or [`ServerEvent::ephemeral`] so the two
/// can never disagree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ServerEvent {
    /// The daemon-wide monotonic counter, `None` on an ephemeral reply.
    pub seq: Option<u64>,
    /// The thread this event belongs to, `None` on an ephemeral reply.
    pub conversation: Option<Uuid>,
    /// The event itself, tagged by `event`.
    #[serde(flatten)]
    pub body: EventBody,
}

impl ServerEvent {
    /// A conversation event, carrying its store seq and its thread.
    #[must_use]
    pub fn persisted(seq: u64, conversation: Uuid, body: EventBody) -> Self {
        Self {
            seq: Some(seq),
            conversation: Some(conversation),
            body,
        }
    }

    /// A per-connection reply, carrying `seq: null` and `conversation: null`.
    ///
    /// # Panics
    ///
    /// In debug builds, when `body` is conversation-scoped. Wrapping one
    /// here would route it around the store: it would reach a client with
    /// no `seq`, never be persisted, and never be replayed. The store's own
    /// [`crate::store::Store::record`] picks the wrapper by scope, so
    /// reaching for this constructor directly with the wrong body is a
    /// mistake rather than a choice.
    #[must_use]
    pub fn ephemeral(body: EventBody) -> Self {
        debug_assert_eq!(
            body.scope(),
            EventScope::Connection,
            "a conversation event needs a seq; record it instead of wrapping it here"
        );
        Self {
            seq: None,
            conversation: None,
            body,
        }
    }
}

/// Which half of the schema an event belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventScope {
    /// Persisted, takes a `seq`, replayed on resume.
    Conversation,
    /// Answers one connection, never stored, `seq` and `conversation` null.
    Connection,
}

/// The body of a daemon event, tagged by `event`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum EventBody {
    /// The handshake reply, sent after the `hello` replay has been flushed.
    Ready {
        /// The protocol version the daemon speaks.
        protocol: u32,
        /// The highest persisted `seq` at connect time.
        seq_head: u64,
    },
    /// A turn opened.
    TurnStart {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// The backend id running the turn.
        backend: String,
        /// `None` until the backend names a model.
        model: Option<String>,
        /// Unix milliseconds.
        started_ms: u64,
    },
    /// A slice of assistant prose. The daemon does not batch these;
    /// `AskBus.qml` coalesces them on a 16ms timer.
    TextDelta {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// The backend's content block index.
        block: u32,
        /// The slice itself.
        text: String,
    },
    /// A slice of thinking. `text` is allowed to stay empty forever: the
    /// harness sends the block structure with an empty string and only a
    /// token estimate, so an empty thinking block is normal, not a bug.
    ThinkingDelta {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// The backend's content block index.
        block: u32,
        /// The slice itself, empty on the harness.
        text: String,
        /// The running estimate, `None` on a backend with none.
        tokens: Option<u32>,
    },
    /// A settled fenced code block, rendered once by the daemon so the pane
    /// does no highlighting on the UI thread.
    CodeBlock {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// The backend's content block index.
        block: u32,
        /// `None` when the fence carried no language tag.
        language: Option<String>,
        /// The code as the model wrote it.
        source: String,
        /// The rich-text subset a QML `Text` draws, `None` until phase 3.
        html: Option<String>,
    },
    /// The model asked to run a tool.
    ToolCall {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// The backend's tool-use id, correlating result, permission and
        /// diff back to this call.
        call: String,
        /// The tool's own name.
        name: String,
        /// `None` when the backend sends no label.
        display_name: Option<String>,
        /// `None` when the backend sends no description.
        summary: Option<String>,
        /// The arguments, carried through untyped: the keys belong to the
        /// backend, not to this schema.
        input: Value,
        /// Whether the harness ran it or an MCP server did.
        origin: ToolOrigin,
    },
    /// What the tool returned. Correlates through `call`, so it carries no
    /// `turn`.
    ToolResult {
        /// The `tool_call.call` this answers.
        call: String,
        /// False only when the backend said so. A missing harness
        /// `is_error` means true.
        ok: bool,
        /// The result text.
        content: String,
        /// Whether the daemon cut `content` short.
        truncated: bool,
    },
    /// The backend wants a decision before it runs a tool. Correlates
    /// through `call`, so it carries no `turn`.
    PermissionRequest {
        /// The backend's own request id, echoed back in `op:"permission"`.
        request: String,
        /// The `tool_call.call` this gates.
        call: String,
        /// The tool's own name.
        name: String,
        /// `None` when the backend sends no label.
        display_name: Option<String>,
        /// `None` when the backend sends no description.
        description: Option<String>,
        /// The arguments, carried through untyped.
        input: Value,
        /// The backend's suggested rules, carried through untyped. Empty
        /// rather than null.
        suggestions: Vec<Value>,
        /// Re-emitted as true when the backend withdraws the request. The
        /// pane must dismiss the prompt and must not answer it.
        withdrawn: bool,
    },
    /// A file change the daemon built from the tool result or the tool
    /// arguments. Correlates through `call`, so it carries no `turn`.
    Diff {
        /// The `tool_call.call` this describes.
        call: String,
        /// The file the tool touched.
        path: PathBuf,
        /// The file before the change.
        old_text: String,
        /// The file after the change.
        new_text: String,
        /// Lines added.
        added: u32,
        /// Lines removed.
        removed: u32,
        /// The rich-text subset a QML `Text` draws, `None` until phase 3.
        html: Option<String>,
    },
    /// A plan the model proposed.
    Plan {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// `None` when the backend sends only a body.
        title: Option<String>,
        /// The plan body as markdown.
        markdown: String,
        /// Where the plan stands.
        state: PlanState,
    },
    /// Token and cost accounting for the turn.
    Usage {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// Prompt tokens.
        input_tokens: u64,
        /// Completion tokens.
        output_tokens: u64,
        /// `None` on every backend but `claude-code` and `anthropic`.
        cache_read_tokens: Option<u64>,
        /// `None` on every backend but `claude-code` and `anthropic`.
        cache_write_tokens: Option<u64>,
        /// `None` on a backend that reports no thinking split.
        thinking_tokens: Option<u64>,
        /// `None` whenever the backend reports no cost, which is always for
        /// `ollama` and `openai-compatible`.
        cost_usd: Option<f64>,
        /// `claude-code` only; the other three report no limit in the
        /// stream.
        rate_limit: Option<RateLimit>,
    },
    /// The turn closed.
    TurnEnd {
        /// The turn this event belongs to.
        turn: Option<Uuid>,
        /// Why it closed.
        stop: StopReason,
        /// The summary text, `None` on an interrupted turn, which sends
        /// none.
        text: Option<String>,
        /// How long the turn ran.
        duration_ms: u64,
    },
    /// Something failed. `kind` alone decides whether this event is
    /// persisted, through [`ErrorKind::scope`].
    Error {
        /// What failed.
        kind: ErrorKind,
        /// What to tell the user.
        message: String,
        /// True when the conversation is dead and the pane should offer a
        /// new one. A connection-scoped error is never fatal, because it
        /// kills no thread.
        fatal: bool,
    },
    /// Conversation metadata, answering `list`, `new` or `delete`.
    Conversations {
        /// The threads, newest first.
        items: Vec<ConversationMeta>,
    },
    /// The backends this daemon can run, and why one is not available.
    Backends {
        /// The registry, in display order.
        items: Vec<BackendInfo>,
    },
}

impl EventBody {
    /// Which half of the schema this event belongs to, and so whether the
    /// server persists it and gives it a `seq`.
    #[must_use]
    pub fn scope(&self) -> EventScope {
        match self {
            Self::Ready { .. } | Self::Conversations { .. } | Self::Backends { .. } => {
                EventScope::Connection
            }
            Self::Error { kind, .. } => kind.scope(),
            Self::TurnStart { .. }
            | Self::TextDelta { .. }
            | Self::ThinkingDelta { .. }
            | Self::CodeBlock { .. }
            | Self::ToolCall { .. }
            | Self::ToolResult { .. }
            | Self::PermissionRequest { .. }
            | Self::Diff { .. }
            | Self::Plan { .. }
            | Self::Usage { .. }
            | Self::TurnEnd { .. } => EventScope::Conversation,
        }
    }
}

/// Whether the harness ran a tool or an MCP server did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolOrigin {
    /// The `claude` CLI ran it.
    Harness,
    /// The daemon ran it through `mcp.rs`.
    Mcp,
}

/// Where a proposed plan stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanState {
    /// The model proposed it and nobody has answered.
    Proposed,
    /// The user accepted it.
    Accepted,
    /// The user rejected it.
    Rejected,
}

/// Why a turn closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    /// The model finished.
    EndTurn,
    /// The model stopped to call a tool.
    ToolUse,
    /// An `op:"interrupt"` stopped it. This arrives alone: a client-driven
    /// interrupt never also raises an `error`.
    Interrupted,
    /// The model hit its output cap.
    MaxTokens,
    /// The turn died; an `error` event carries the reason.
    Error,
}

/// What failed, and with it whether the `error` event is persisted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// The backend process failed to start, or died mid-turn.
    BackendSpawn,
    /// The backend sent something the decoder could not use.
    Protocol,
    /// The provider refused the credential.
    Auth,
    /// The provider or the plan refused the request.
    RateLimit,
    /// The backend abandoned a turn on its own, with no `op:"interrupt"`
    /// behind it. The opposite case is [`StopReason::Interrupted`], and the
    /// two never both fire for one turn.
    Cancelled,
    /// The client sent an unparseable line, an `op` the daemon does not
    /// have, or an argument it cannot resolve.
    BadRequest,
    /// The daemon could not read or write the conversation store.
    Store,
}

impl ErrorKind {
    /// Which half of the schema an `error` of this kind belongs to.
    ///
    /// [`Self::Store`] is connection-scoped by definition, because writing
    /// the record is the thing that just failed. [`Self::BadRequest`] is
    /// connection-scoped because a frame the daemon cannot act on names no
    /// thread to file the failure under.
    #[must_use]
    pub fn scope(self) -> EventScope {
        match self {
            Self::BackendSpawn
            | Self::Protocol
            | Self::Auth
            | Self::RateLimit
            | Self::Cancelled => EventScope::Conversation,
            Self::BadRequest | Self::Store => EventScope::Connection,
        }
    }
}

/// The provider's rate limit state, folded into `usage`.
///
/// This comes straight off the harness `rate_limit_event` and nothing else
/// produces it, so the three fields keep the harness's own value spaces and
/// stay `String`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimit {
    /// The harness `rateLimitType`, for example `five_hour`.
    #[serde(rename = "type")]
    pub kind: String,
    /// The harness `status`, for example `allowed`.
    pub status: String,
    /// The harness `resetsAt`, unix seconds.
    pub resets_at: u64,
}

/// One row of a `conversations` event, and one row of the store index.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversationMeta {
    /// The client-minted thread id.
    pub id: Uuid,
    /// `None` until the first turn names the thread.
    pub title: Option<String>,
    /// The backend id the thread runs on.
    pub backend: String,
    /// `None` while the thread still uses the backend default.
    pub model: Option<String>,
    /// The working directory the thread is scoped to.
    pub cwd: PathBuf,
    /// Unix milliseconds of the last event appended.
    pub updated_ms: u64,
    /// How many turns have closed.
    pub turns: u32,
}

/// One row of a `backends` event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BackendInfo {
    /// The id a `new` frame names.
    pub id: String,
    /// What the pane shows.
    pub label: String,
    /// Whether the backend can run.
    pub state: BackendState,
    /// The models the pane offers, empty rather than null.
    pub models: Vec<String>,
    /// Why the backend is not `ready`, `None` when it is.
    pub detail: Option<String>,
}

/// Whether a backend can run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BackendState {
    /// Configured and reachable.
    Ready,
    /// The toggle is on but there is no credential.
    Unconfigured,
    /// The service refused a connection.
    Unreachable,
}

// -- seq allocation --------------------------------------------------------

/// The daemon-wide monotonic `seq`.
///
/// One counter spans every conversation, and it is handed out at emit time
/// under the same lock that appends to the store, so the numbers a client
/// sees are in the order they were written. That is the whole reason the
/// counter has no holes and replay from `resume_seq` is exact.
#[derive(Debug, Default)]
pub struct SeqCounter {
    head: u64,
}

impl SeqCounter {
    /// Continue a counter that a previous run left at `head`.
    ///
    /// `0` means nothing has been persisted yet, so the first allocation
    /// returns `1` and `seq` values are always non-zero.
    #[must_use]
    pub fn resuming_from(head: u64) -> Self {
        Self { head }
    }

    /// The highest `seq` handed out so far, which is what `ready.seq_head`
    /// reports.
    #[must_use]
    pub fn head(&self) -> u64 {
        self.head
    }

    /// Hand out the next `seq`.
    pub fn allocate(&mut self) -> u64 {
        self.head += 1;
        self.head
    }
}

// -- decoding a client line ------------------------------------------------

/// Turn one client line into a frame, or into the message a connection-scoped
/// [`ErrorKind::BadRequest`] should carry.
///
/// A line that parses as JSON but names an `op` this daemon does not have
/// gets a message that quotes the op back, because that is the mistake a
/// client author actually makes. Anything else reports the serde error.
///
/// # Errors
///
/// Returns the human-readable message for the `error` event when the line is
/// not a frame this daemon can act on. The connection stays open either way.
pub fn decode_client_line(line: &str) -> Result<ClientFrame, String> {
    match serde_json::from_str::<ClientFrame>(line) {
        Ok(frame) => Ok(frame),
        Err(err) => Err(explain_decode_failure(line, &err)),
    }
}

/// Build the `error.message` for a line that did not decode.
fn explain_decode_failure(line: &str, err: &serde_json::Error) -> String {
    // Re-parse loosely so an unknown `op` reads as an unknown op rather than
    // as serde's "unknown variant" wording, which names Rust variants the
    // client author has never seen.
    let Ok(loose) = serde_json::from_str::<BTreeMap<String, Value>>(line) else {
        return format!("malformed frame: {err}");
    };
    match loose.get("op") {
        Some(Value::String(op)) if !is_known_op(op) => format!("unknown op {op:?}"),
        Some(Value::String(op)) => format!("op {op:?} is missing or has a bad field: {err}"),
        Some(_) => "frame field \"op\" is not a string".to_owned(),
        None => "frame has no \"op\" field".to_owned(),
    }
}

/// Whether `op` names a frame this daemon has.
fn is_known_op(op: &str) -> bool {
    matches!(
        op,
        "hello" | "list" | "open" | "new" | "send" | "interrupt" | "permission" | "delete"
    )
}

/// Encode one daemon event as the single line that goes on the wire,
/// newline included.
///
/// # Errors
///
/// Returns the `serde_json` failure. Every type in this module is plain
/// data, so in practice this only fires on a non-finite `cost_usd`, which no
/// backend produces.
pub fn encode_server_line(event: &ServerEvent) -> Result<String, serde_json::Error> {
    let mut line = serde_json::to_string(event)?;
    line.push('\n');
    Ok(line)
}
