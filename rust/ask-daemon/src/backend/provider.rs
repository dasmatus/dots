//! What the three raw-provider adapters share: the HTTP stream, the message
//! history, the tool loop, and the approval gate in front of it.
//!
//! A harness backend hands its tools to a CLI that already has an approval
//! protocol. A raw provider has none, so everything the CLI would have done
//! has to happen here, and section 5 of the spec is the shape of it:
//!
//! - **v1 ships no built-in shell tool and no built-in file write tool.**
//!   There is no code in this module that runs a command a model named. The
//!   only tools a provider can call are the ones `mcp.rs` discovered from
//!   servers a person already configured, and a name outside that set gets a
//!   synthesized error result rather than an execution.
//! - **Every call still passes through `policy.rs`**, so the pane shows the
//!   same approval prompt it shows in harness mode.
//!
//! ## Why the turn loop owns the command channel
//!
//! An approval arrives as a `BackendCommand::Permission` on the same channel
//! the next `send` would arrive on. So a turn that is waiting for a decision
//! has to keep reading that channel, or the decision it is waiting for can
//! never be delivered. [`ProviderSession::run_turn`] therefore takes the
//! receiver and selects over it while the stream is running and while a
//! decision is outstanding. The alternative, a separate task per turn with a
//! second channel, would put the two in a race over which one gets the next
//! `interrupt`.
//!
//! ## Raw providers emit no plan and no diff
//!
//! Both come from harness tools, and in provider mode there are no file
//! tools at all, by design. `Backend::produces_diffs_and_plans` reports
//! false for all three so the pane can hide those surfaces rather than wait
//! for data that never comes.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::attach;
use crate::backend::{BackendCommand, BackendContext, EventSink};
use crate::mcp::McpPool;
use crate::policy::{Policy, PolicyKey, Verdict};
use crate::proto::{
    ErrorKind, EventBody, PermissionDecision, PermissionScope, SendBlock, StopReason, ToolOrigin,
};
use crate::render;
use crate::server::now_ms;

/// How long a provider request may take from connect to last byte.
///
/// Generous, because a long answer from a slow local model is normal, but
/// finite, because a stream that stalls forever leaves a turn open forever
/// and the pane has no way to tell that from thinking.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(600);

/// How many tool rounds one turn may take before the daemon stops.
///
/// A model that keeps asking for tools is either working or looping, and
/// nothing in the stream distinguishes the two. The cap turns the second
/// case into a turn that ends and says why.
const MAX_TOOL_ROUNDS: usize = 8;

/// How many bytes of a tool result reach the pane and the model.
const MAX_TOOL_RESULT: usize = 16 * 1024;

/// The shared HTTP client.
///
/// One client, so the connection pool and the TLS session cache are shared
/// across every provider turn rather than rebuilt per request.
static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

/// Borrow the shared HTTP client.
#[must_use]
pub fn client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent(concat!("dots-ask/", env!("CARGO_PKG_VERSION")))
            .build()
            .unwrap_or_default()
    })
}

/// One tool call a provider asked for, with its arguments as raw JSON text.
///
/// Text rather than a `Value`, because two of the three providers stream the
/// arguments as fragments that only parse once the last fragment arrives.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PendingToolCall {
    /// The provider's own id for the call, echoed back with the result.
    pub id: String,
    /// The tool's name.
    pub name: String,
    /// The arguments, as the provider spelled them.
    pub arguments: String,
}

impl PendingToolCall {
    /// The arguments as JSON, or null when the provider sent nothing usable.
    #[must_use]
    pub fn input(&self) -> Value {
        if self.arguments.trim().is_empty() {
            return Value::Null;
        }
        serde_json::from_str(&self.arguments).unwrap_or(Value::Null)
    }
}

/// Turns one provider's byte stream into normalized events.
///
/// Each adapter implements this over its own wire format, and everything
/// else in this module is written once against the trait. It holds no I/O,
/// which is what lets each adapter's test drive it off a recorded fixture.
pub trait ChunkDecoder: Default + Send {
    /// Feed one chunk of the response body.
    fn push(&mut self, chunk: &str) -> Vec<EventBody>;

    /// Flush whatever the last chunk left incomplete.
    ///
    /// A server that ends without a final newline still sent a whole
    /// message, and dropping it would lose the end of a turn.
    fn finish(&mut self) -> Vec<EventBody> {
        Vec::new()
    }

    /// The tool calls this turn asked for, taken out of the decoder.
    fn take_tool_calls(&mut self) -> Vec<PendingToolCall>;

    /// Why the turn ended, as far as the stream said.
    fn stop(&self) -> StopReason;

    /// The assistant prose this turn produced, for `turn_end.text`.
    fn take_text(&mut self) -> String;
}

/// One provider-backed conversation.
pub struct ProviderSession {
    /// Where normalized events go.
    pub sink: EventSink,
    /// The MCP servers this thread may call tools on.
    pub mcp: Arc<McpPool>,
    /// The approval store, shared with the hub so a `forever` rule written
    /// here is the same rule the next thread reads.
    pub policy: Arc<Mutex<Policy>>,
    /// The thread's working directory, which is part of every policy key.
    pub cwd: PathBuf,
    /// The backend id, which is the other part.
    pub backend: &'static str,
    /// How this provider takes a user message and its attachments.
    shape: UserShape,
    /// The conversation history, in the provider's own message shape.
    messages: Vec<Value>,
    /// Decisions that have arrived and are waiting to be matched to the
    /// request that is blocking.
    decisions: BTreeMap<String, Answer>,
    /// Set by an `interrupt` while a turn is running.
    interrupted: bool,
}

/// One answered permission request.
#[derive(Debug, Clone)]
struct Answer {
    decision: PermissionDecision,
    scope: PermissionScope,
    updated_input: Option<Value>,
    message: Option<String>,
}

/// How one provider takes a user message that carries attachments.
///
/// Three shapes because three providers, and none of them is a superset of
/// another. Section 3 of the spec carries the same table in prose; this is
/// the enum that makes a backend pick exactly one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserShape {
    /// `content` is an array of blocks, an image being
    /// `{"type":"image","source":{"type":"base64",…}}`.
    AnthropicBlocks,
    /// `content` is an array of parts, an image being
    /// `{"type":"image_url","image_url":{"url":"data:…"}}`.
    OpenAiParts,
    /// `content` is a plain string and images ride a sibling `images` array
    /// of bare base64, with no media type and no data URL.
    OllamaImages,
}

impl ProviderSession {
    /// A session for one thread.
    #[must_use]
    pub fn new(ctx: &BackendContext, backend: &'static str, shape: UserShape) -> Self {
        Self {
            sink: ctx.sink.clone(),
            mcp: Arc::clone(&ctx.mcp),
            policy: Arc::clone(&ctx.policy),
            cwd: ctx.cwd.clone(),
            backend,
            shape,
            messages: Vec::new(),
            decisions: BTreeMap::new(),
            interrupted: false,
        }
    }

    /// The conversation so far, in the provider's message shape.
    #[must_use]
    pub fn messages(&self) -> &[Value] {
        &self.messages
    }

    /// Append one message the provider will see.
    pub fn push_message(&mut self, message: Value) {
        self.messages.push(message);
    }

    /// Append the user's message, in this provider's own attachment shape.
    ///
    /// The three providers disagree about how an image reaches them and
    /// agree about nothing else, so the shape is a field rather than a
    /// branch on `self.backend`: a stringly-typed match here would be the
    /// one place a new provider could silently take the wrong encoding.
    ///
    /// An attachment that is not an inlinable image is still named as a path
    /// rather than read. This daemon does not read arbitrary files on a
    /// model's behalf; an MCP server a person configured can.
    pub fn push_user(&mut self, blocks: &[SendBlock]) {
        let message = match self.shape {
            UserShape::AnthropicBlocks => {
                json!({"role": "user", "content": attach::anthropic_content(blocks)})
            }
            UserShape::OpenAiParts => {
                json!({"role": "user", "content": attach::openai_content(blocks)})
            }
            UserShape::OllamaImages => attach::ollama_message(blocks),
        };
        self.messages.push(message);
    }

    /// Note that the client asked for the turn to stop.
    pub fn interrupt(&mut self) {
        self.interrupted = true;
    }

    /// File a decision that arrived from the client.
    ///
    /// Filed rather than acted on, because the turn that asked may not be
    /// the thing reading the channel at this instant. [`Self::wait_for`]
    /// picks it up.
    pub fn answer(
        &mut self,
        request: String,
        decision: PermissionDecision,
        scope: PermissionScope,
        updated_input: Option<Value>,
        message: Option<String>,
    ) {
        self.decisions.insert(
            request,
            Answer {
                decision,
                scope,
                updated_input,
                message,
            },
        );
    }

    /// Run one whole turn: the completion, then any tool rounds it asked
    /// for, then `turn_end`.
    ///
    /// Returns false when the daemon has gone away and the backend should
    /// stop.
    pub async fn run_turn<D: ChunkDecoder>(
        &mut self,
        model: Option<&str>,
        request: &TurnRequest,
        inbox: &mut mpsc::UnboundedReceiver<BackendCommand>,
    ) -> bool {
        self.interrupted = false;
        let started = now_ms();
        if !self.sink.emit(EventBody::TurnStart {
            turn: None,
            backend: self.backend.to_owned(),
            model: model.map(str::to_owned),
            started_ms: started,
        }) {
            return false;
        }

        let mut stop = StopReason::EndTurn;
        let mut summary = String::new();
        for round in 0..MAX_TOOL_ROUNDS {
            let body = request.body(self.messages());
            let Some(outcome) = self.stream_once::<D>(request, &body, inbox).await else {
                return false;
            };
            stop = outcome.stop;
            if !outcome.text.is_empty() {
                summary = outcome.text;
            }
            if self.interrupted {
                stop = StopReason::Interrupted;
                break;
            }
            if outcome.tool_calls.is_empty() || outcome.failed {
                break;
            }
            if round + 1 == MAX_TOOL_ROUNDS {
                self.sink.fail(
                    ErrorKind::Protocol,
                    format!("the model asked for tools {MAX_TOOL_ROUNDS} rounds running; stopping the turn"),
                    false,
                );
                stop = StopReason::Error;
                break;
            }
            if !self.run_tools(request, outcome.tool_calls, inbox).await {
                return false;
            }
        }

        self.sink.emit(EventBody::TurnEnd {
            turn: None,
            stop,
            text: (stop != StopReason::Interrupted && !summary.is_empty()).then_some(summary),
            duration_ms: now_ms().saturating_sub(started),
        })
    }

    /// One completion request, streamed to its end.
    ///
    /// `None` means the daemon has gone away.
    async fn stream_once<D: ChunkDecoder>(
        &mut self,
        request: &TurnRequest,
        body: &Value,
        inbox: &mut mpsc::UnboundedReceiver<BackendCommand>,
    ) -> Option<TurnOutcome> {
        let mut send = client()
            .post(&request.url)
            .timeout(REQUEST_TIMEOUT)
            .json(body);
        for (name, value) in &request.headers {
            send = send.header(name, value);
        }

        let response = match send.send().await {
            Ok(response) => response,
            Err(err) => {
                self.sink.fail(
                    ErrorKind::BackendSpawn,
                    format!("cannot reach {}: {err}", request.url),
                    false,
                );
                return Some(TurnOutcome::failed());
            }
        };
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await.unwrap_or_default();
            self.sink.fail(
                http_error_kind(status),
                http_error_message(status, &text),
                false,
            );
            return Some(TurnOutcome::failed());
        }

        let mut decoder = D::default();
        let mut stream = response.bytes_stream();
        loop {
            tokio::select! {
                chunk = stream.next() => match chunk {
                    Some(Ok(bytes)) => {
                        let text = String::from_utf8_lossy(&bytes);
                        for body in decoder.push(&text) {
                            if !self.sink.emit(body) {
                                return None;
                            }
                        }
                    }
                    Some(Err(err)) => {
                        self.sink.fail(
                            ErrorKind::Protocol,
                            format!("the response stream broke: {err}"),
                            false,
                        );
                        return Some(TurnOutcome::failed());
                    }
                    None => break,
                },
                command = inbox.recv() => match command {
                    // The stream is dropped when this function returns, and
                    // dropping a reqwest response cancels the request, which
                    // is the whole of an interrupt for a provider.
                    Some(BackendCommand::Interrupt) => {
                        self.interrupt();
                        break;
                    }
                    Some(BackendCommand::Permission { request, decision, scope, updated_input, message }) => {
                        self.answer(request, decision, scope, updated_input, message);
                    }
                    // A send that arrives mid-turn is queued as a message
                    // and answered by the next round rather than dropped.
                    Some(BackendCommand::Send { blocks }) => self.push_user(&blocks),
                    Some(BackendCommand::Shutdown) | None => return None,
                },
            }
        }
        for body in decoder.finish() {
            if !self.sink.emit(body) {
                return None;
            }
        }

        Some(TurnOutcome {
            stop: decoder.stop(),
            text: decoder.take_text(),
            tool_calls: decoder.take_tool_calls(),
            failed: false,
        })
    }

    /// Approve, refuse and run each tool the model asked for.
    ///
    /// Returns false when the daemon has gone away.
    async fn run_tools(
        &mut self,
        request: &TurnRequest,
        calls: Vec<PendingToolCall>,
        inbox: &mut mpsc::UnboundedReceiver<BackendCommand>,
    ) -> bool {
        for call in calls {
            let mut input = call.input();
            if !self.sink.emit(EventBody::ToolCall {
                turn: None,
                call: call.id.clone(),
                name: call.name.clone(),
                display_name: None,
                summary: None,
                input: input.clone(),
                origin: ToolOrigin::Mcp,
            }) {
                return false;
            }

            let approval = self.approve(&call, &input, inbox).await;
            let outcome = match approval {
                Approval::Gone => return false,
                Approval::Denied(reason) => Err(reason),
                Approval::Allowed(edited) => {
                    if let Some(edited) = edited {
                        input = edited;
                    }
                    self.invoke(&call.name, &input).await
                }
            };

            let (ok, content) = match outcome {
                Ok(text) => (true, text),
                Err(text) => (false, text),
            };
            let truncated = content.len() > MAX_TOOL_RESULT;
            if !self.sink.emit(EventBody::ToolResult {
                call: call.id.clone(),
                ok,
                content: truncate(&content, MAX_TOOL_RESULT),
                truncated,
            }) {
                return false;
            }
            request.push_tool_result(self, &call, ok, &truncate(&content, MAX_TOOL_RESULT));
        }
        true
    }

    /// Decide whether one tool call may run, asking the client if nothing
    /// already decides it.
    async fn approve(
        &mut self,
        call: &PendingToolCall,
        input: &Value,
        inbox: &mut mpsc::UnboundedReceiver<BackendCommand>,
    ) -> Approval {
        let key = PolicyKey::new(self.backend, &call.name, &self.cwd, input);
        let conversation = self.sink.conversation();
        let verdict = match self.policy.lock() {
            Ok(policy) => policy.decide(conversation, &key),
            Err(poisoned) => poisoned.into_inner().decide(conversation, &key),
        };
        match verdict {
            Verdict::Allow => return Approval::Allowed(None),
            Verdict::Deny => {
                return Approval::Denied(format!(
                    "{:?} is not a tool this backend may run",
                    call.name
                ))
            }
            Verdict::Ask => {}
        }

        // The daemon mints the request id, because a raw provider has no
        // permission protocol of its own and so no id to echo.
        let request = Uuid::new_v4().to_string();
        if !self.sink.emit(EventBody::PermissionRequest {
            request: request.clone(),
            call: call.id.clone(),
            name: call.name.clone(),
            display_name: None,
            description: None,
            input: input.clone(),
            suggestions: Vec::new(),
            withdrawn: false,
        }) {
            return Approval::Gone;
        }

        let Some(answer) = self.wait_for(&request, inbox).await else {
            return Approval::Gone;
        };
        // Remember before acting, so a daemon that dies running the tool
        // still comes back knowing the person approved it.
        self.remember(call, input, answer.decision, answer.scope);
        if answer.decision == PermissionDecision::Deny {
            return Approval::Denied(
                answer
                    .message
                    .unwrap_or_else(|| "denied from the ask pane".to_owned()),
            );
        }
        Approval::Allowed(answer.updated_input)
    }

    /// Block until the decision for `request` arrives, still serving the
    /// other commands that can turn up meanwhile.
    async fn wait_for(
        &mut self,
        request: &str,
        inbox: &mut mpsc::UnboundedReceiver<BackendCommand>,
    ) -> Option<Answer> {
        loop {
            if let Some(answer) = self.decisions.remove(request) {
                return Some(answer);
            }
            if self.interrupted {
                return Some(Answer {
                    decision: PermissionDecision::Deny,
                    // Once, so an interrupt never writes a rule. The person
                    // stopped the turn; they did not decide about the tool.
                    scope: PermissionScope::Once,
                    updated_input: None,
                    message: Some("the turn was interrupted".to_owned()),
                });
            }
            match inbox.recv().await? {
                BackendCommand::Permission {
                    request: id,
                    decision,
                    scope,
                    updated_input,
                    message,
                } => self.answer(id, decision, scope, updated_input, message),
                BackendCommand::Interrupt => self.interrupt(),
                BackendCommand::Send { blocks } => self.push_user(&blocks),
                BackendCommand::Shutdown => return None,
            }
        }
    }

    /// Record what the client decided, so the same call does not ask twice.
    fn remember(
        &self,
        call: &PendingToolCall,
        input: &Value,
        decision: PermissionDecision,
        scope: PermissionScope,
    ) {
        let key = PolicyKey::new(self.backend, &call.name, &self.cwd, input);
        let conversation = self.sink.conversation();
        let mut policy = match self.policy.lock() {
            Ok(policy) => policy,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Err(err) = policy.remember(conversation, key, decision, scope) {
            tracing::warn!(error = %err, "could not persist a forever decision");
        }
    }

    /// Run one MCP tool.
    ///
    /// A name no configured server exposes gets a synthesized error rather
    /// than an execution, which is section 5's rule stated as code.
    async fn invoke(&self, tool: &str, input: &Value) -> Result<String, String> {
        let Some((server, name)) = self.locate(tool).await else {
            return Err(format!(
                "no configured MCP server exposes a tool named {tool:?}, and dots-ask ships no built-in tools"
            ));
        };
        self.mcp.call(&server, &name, input).await
    }

    /// Which server exposes `tool`, and under what name.
    async fn locate(&self, tool: &str) -> Option<(String, String)> {
        self.mcp
            .list_tools()
            .await
            .into_iter()
            .find(|known| qualified_name(&known.server, &known.name) == tool || known.name == tool)
            .map(|known| (known.server, known.name))
    }
}

/// What [`ProviderSession::approve`] concluded.
enum Approval {
    /// The call may run, with these arguments if the user edited them.
    Allowed(Option<Value>),
    /// The call may not run, and this is what the model is told.
    Denied(String),
    /// The daemon has gone away.
    Gone,
}

/// What one streamed completion produced.
struct TurnOutcome {
    stop: StopReason,
    text: String,
    tool_calls: Vec<PendingToolCall>,
    failed: bool,
}

impl TurnOutcome {
    /// The outcome of a request that never produced a stream.
    fn failed() -> Self {
        Self {
            stop: StopReason::Error,
            text: String::new(),
            tool_calls: Vec::new(),
            failed: true,
        }
    }
}

/// Builds one request body from the conversation history.
pub type BuildBody = Box<dyn Fn(&[Value]) -> Value + Send + Sync>;

/// Turns one tool result into the history entry its provider expects.
pub type RecordResult = Box<dyn Fn(&PendingToolCall, bool, &str) -> Value + Send + Sync>;

/// Everything one provider needs to build and address a request.
///
/// The body is built per round, because each round appends the previous
/// round's tool results to the history.
pub struct TurnRequest {
    /// Where to post.
    pub url: String,
    /// Headers the provider needs, credentials included.
    pub headers: Vec<(String, String)>,
    /// Builds the request body from the history.
    pub build: BuildBody,
    /// Appends one tool result to the history in the provider's own shape,
    /// which is the one place the three genuinely differ.
    pub record_result: RecordResult,
}

impl TurnRequest {
    /// The body for one round.
    #[must_use]
    pub fn body(&self, messages: &[Value]) -> Value {
        (self.build)(messages)
    }

    /// Append one tool result to the session history.
    fn push_tool_result(
        &self,
        session: &mut ProviderSession,
        call: &PendingToolCall,
        ok: bool,
        content: &str,
    ) {
        session.push_message((self.record_result)(call, ok, content));
    }
}

/// The tool schemas to advertise to a provider.
///
/// Empty when no MCP server is configured, which correctly tells the model
/// it has no tools rather than offering it ones that would fail.
pub async fn tool_schemas(mcp: &McpPool) -> Vec<Value> {
    mcp.list_tools()
        .await
        .into_iter()
        .map(|tool| {
            json!({
                "type": "function",
                "function": {
                    "name": qualified_name(&tool.server, &tool.name),
                    "description": tool.description.unwrap_or_default(),
                    "parameters": tool.input_schema,
                },
            })
        })
        .collect()
}

/// A tool's name as the model sees it.
///
/// Prefixed with the server, because two servers may expose a `search` and
/// the model has to be able to pick one.
#[must_use]
pub fn qualified_name(server: &str, tool: &str) -> String {
    format!("{server}__{tool}")
}

/// The `error.kind` an HTTP status maps to.
#[must_use]
pub fn http_error_kind(status: reqwest::StatusCode) -> ErrorKind {
    match status.as_u16() {
        401 | 403 => ErrorKind::Auth,
        429 => ErrorKind::RateLimit,
        _ => ErrorKind::Protocol,
    }
}

/// The message an HTTP failure carries.
///
/// Both provider families put a usable sentence in the body, under
/// `error.message` for OpenAI-compatible servers and `error.type` plus
/// `error.message` for Anthropic, so the body is preferred over the status
/// line whenever it parses.
#[must_use]
pub fn http_error_message(status: reqwest::StatusCode, body: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .pointer("/error/message")
                .or_else(|| value.pointer("/error/type"))
                .or_else(|| value.get("error"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_else(|| truncate(body.trim(), 400));
    if detail.is_empty() {
        return format!("the provider answered {status}");
    }
    format!("the provider answered {status}: {detail}")
}

/// A conversation-scoped `protocol` error, never fatal.
#[must_use]
pub fn protocol_error(message: String) -> EventBody {
    EventBody::Error {
        kind: ErrorKind::Protocol,
        message,
        fatal: false,
    }
}

/// A conversation-scoped error the provider itself reported in its body.
#[must_use]
pub fn api_error(message: String) -> EventBody {
    EventBody::Error {
        kind: ErrorKind::Protocol,
        message,
        fatal: false,
    }
}

/// Render the fenced code in a settled assistant message.
///
/// Every provider settles its text the same way, at the end of a stream, so
/// the three adapters share this rather than each carrying a copy.
#[must_use]
pub fn code_block_events(text: &str, block: u32) -> Vec<EventBody> {
    render::code_blocks(text)
        .into_iter()
        .map(|code| EventBody::CodeBlock {
            turn: None,
            block,
            html: Some(render::code_block_html(
                &code.source,
                code.language.as_deref(),
            )),
            language: code.language,
            source: code.source,
        })
        .collect()
}

/// Cut a string to `limit` bytes on a character boundary.
#[must_use]
pub fn truncate(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}
