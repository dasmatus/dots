//! The `claude` CLI as a backend: argv, the `initialize` handshake, the
//! stream-json decode, and the control envelope in both directions.
//!
//! Section 1 of the spec is the authority for every shape here, and
//! `tests/fixtures/claude-stream.jsonl` is the recording it was written
//! from. The interface is undocumented and carries no compatibility promise,
//! so `tests/claude_code.rs` replays that file: after a `claude` upgrade the
//! test fails loudly instead of the pane going quiet.
//!
//! ## The flag that is not in --help
//!
//! `--permission-prompt-tool stdio` is mandatory and does not appear in
//! `claude --help`. The first spike ran without it, and the CLI resolved
//! permissions internally: it printed
//! `{"type":"system","subtype":"permission_denied",...}` and handed the
//! model an error `tool_result`, and no `control_request` ever reached the
//! driver. A daemon that drops it as unrecognised gets a session where every
//! gated tool silently fails and the approval UI never fires once.
//!
//! `--permission-mode manual` normalizes to `default` inside the bundle. The
//! fixture proves it: all three `system/init` lines report
//! `"permissionMode":"default"` although the CLI was launched with `manual`,
//! and `Write` was still gated rather than pre-approved.
//!
//! ## Three decoding rules the fixture forced
//!
//! **A missing `is_error` means success.** Only the two non-execution paths
//! set it, and only ever to `true`. The allowed write at fixture line 81 has
//! no `is_error` key at all.
//!
//! **`tool_use_result` is polymorphic.** It is a string on the two
//! non-execution paths and a tool-specific object on the success path, so it
//! is decoded as an untyped value and never as a string.
//!
//! **`terminal_reason` decides the stop, not `is_error`.** The CLI marks a
//! client interrupt as a failure: the third turn ends with
//! `subtype: "error_during_execution"` and `is_error: true`. The daemon does
//! not, because the client asked for it. `aborted_tools` is
//! `stop: "interrupted"` with no `error` event beside it.
//!
//! ## Answering every control request
//!
//! The CLI can send three subtypes, and only `can_use_tool` was ever
//! exercised. An unanswered control request stalls the turn with no visible
//! cause, so the other two are refused explicitly rather than ignored: a
//! `deny` response naming the subtype, plus an `error` event with
//! `kind: "protocol"` so the pane shows that something went unhandled.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Stdio;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::backend::{
    on_path, unavailable, Backend, BackendCommand, BackendContext, BackendHandle, EventSink,
    CLAUDE_CODE,
};
use crate::proto::{
    BackendInfo, BackendState, BlockKind, ErrorKind, EventBody, PermissionDecision, SendBlock,
    StopReason, ToolOrigin,
};
use crate::render;
use crate::secrets::SecretStore;

/// The CLI this backend drives.
const PROGRAM: &str = "claude";

/// The models the pane offers for this backend.
///
/// Aliases rather than full ids, because that is what `--model` takes and
/// what the settled `system/init` line resolves for us anyway.
const MODELS: [&str; 3] = ["opus", "sonnet", "haiku"];

/// The `initialize` request id the daemon mints.
///
/// Client-minted ids are free-form strings; the spike used exactly this one
/// and the CLI accepted it.
const INIT_REQUEST: &str = "req_0_init";

/// How many bytes of a tool result reach the pane before it is cut.
///
/// A `Read` of a large file comes back whole, and a transcript is not the
/// place for a megabyte of it. The event carries `truncated` so the pane can
/// say the result was cut rather than showing a sentence that stops.
const MAX_TOOL_RESULT: usize = 16 * 1024;

/// The `claude` CLI, if it is installed.
pub struct ClaudeCodeBackend {
    program: Option<PathBuf>,
}

impl ClaudeCodeBackend {
    /// Look for `claude` on `PATH` once, at registry build time.
    #[must_use]
    pub fn detected() -> Self {
        Self {
            program: on_path(PROGRAM),
        }
    }

    /// A backend pinned to one binary, which is how a test points at a fake
    /// CLI without putting it on `PATH`.
    #[must_use]
    pub fn at(program: PathBuf) -> Self {
        Self {
            program: Some(program),
        }
    }
}

impl Backend for ClaudeCodeBackend {
    fn id(&self) -> &'static str {
        CLAUDE_CODE
    }

    fn info(&self, _secrets: &SecretStore) -> BackendInfo {
        let Some(program) = &self.program else {
            return unavailable(
                CLAUDE_CODE,
                "Claude Code",
                format!("{PROGRAM} is not on PATH; turn dots.ai.claude on"),
            );
        };
        BackendInfo {
            id: CLAUDE_CODE.to_owned(),
            label: "Claude Code".to_owned(),
            state: BackendState::Ready,
            models: MODELS.iter().map(|name| (*name).to_owned()).collect(),
            // Section 5 calls this widening out rather than hiding it. The
            // harness still applies ~/.claude/settings.json, so a tool that
            // matches an allow rule there is approved inside the CLI and
            // never reaches this pane at all.
            detail: Some(format!(
                "{}; tools allowed by ~/.claude/settings.json are approved inside the CLI and never prompt here",
                program.display()
            )),
        }
    }

    fn produces_diffs_and_plans(&self) -> bool {
        true
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let program = self
            .program
            .clone()
            .ok_or_else(|| format!("{PROGRAM} is not on PATH"))?;
        let session = Uuid::new_v4();
        let mut command = Command::new(&program);
        command
            .args(argv(session, ctx.model.as_deref()))
            .current_dir(&ctx.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command
            .spawn()
            .map_err(|err| format!("cannot spawn {}: {err}", program.display()))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "the CLI was spawned without a stdin pipe".to_owned())?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "the CLI was spawned without a stdout pipe".to_owned())?;
        let stderr = child.stderr.take();

        let (commands, inbox) = mpsc::unbounded_channel();
        tokio::spawn(run(Session { child, stdin }, stdout, stderr, inbox, ctx));
        Ok(BackendHandle::new(commands))
    }
}

/// The argv the spec's section 1 recorded, minus the fixture-only flags.
///
/// `--verbose` and `--add-dir` were the driver's, not the daemon's: the
/// working directory is set on the child rather than passed as a flag, and
/// the daemon has no use for the extra logging.
#[must_use]
pub fn argv(session: Uuid, model: Option<&str>) -> Vec<String> {
    let mut args = vec![
        "-p".to_owned(),
        "--input-format".to_owned(),
        "stream-json".to_owned(),
        "--output-format".to_owned(),
        "stream-json".to_owned(),
        "--include-partial-messages".to_owned(),
        "--permission-mode".to_owned(),
        "manual".to_owned(),
        // Undocumented and mandatory. Without it the CLI resolves
        // permissions itself and no control_request ever arrives.
        "--permission-prompt-tool".to_owned(),
        "stdio".to_owned(),
        "--session-id".to_owned(),
        session.to_string(),
    ];
    if let Some(model) = model {
        args.push("--model".to_owned());
        args.push(model.to_owned());
    }
    args
}

/// The argv for resuming an existing CLI session.
///
/// A model change and a backend switch both take this path: v1 closes the
/// child and respawns with `--resume` and the new `--model`, because the
/// bundle's `set_model` control subtype was never exercised and stays
/// unverified.
#[must_use]
pub fn resume_argv(session: Uuid, model: Option<&str>) -> Vec<String> {
    let mut args = argv(session, model);
    args.push("--resume".to_owned());
    args.push(session.to_string());
    args
}

/// The child process and the pipe the daemon writes control traffic to.
struct Session {
    child: Child,
    stdin: ChildStdin,
}

impl Session {
    /// Write one line to the CLI's stdin.
    async fn write(&mut self, line: &Value) -> bool {
        let mut text = match serde_json::to_string(line) {
            Ok(text) => text,
            Err(err) => {
                tracing::error!(error = %err, "dropping a control frame that will not encode");
                return true;
            }
        };
        text.push('\n');
        if let Err(err) = self.stdin.write_all(text.as_bytes()).await {
            tracing::warn!(error = %err, "the CLI closed its stdin");
            return false;
        }
        self.stdin.flush().await.is_ok()
    }
}

/// Drive one CLI session until the child ends or the daemon shuts it down.
async fn run(
    mut session: Session,
    stdout: tokio::process::ChildStdout,
    stderr: Option<tokio::process::ChildStderr>,
    mut inbox: mpsc::UnboundedReceiver<BackendCommand>,
    ctx: BackendContext,
) {
    if let Some(stderr) = stderr {
        tokio::spawn(drain_stderr(stderr, ctx.conversation));
    }

    // The client speaks first. Nothing is decoded from the reply beyond the
    // fact that it arrived: the capability list it carries names commands
    // and agents the pane has no surface for.
    session
        .write(&json!({
            "type": "control_request",
            "request_id": INIT_REQUEST,
            "request": {"subtype": "initialize", "hooks": {}},
        }))
        .await;

    let mut decoder = StreamDecoder::new(ctx.model.clone());
    let mut lines = BufReader::new(stdout).lines();
    let mut interrupts = 0_u32;

    loop {
        tokio::select! {
            line = lines.next_line() => match line {
                Ok(Some(line)) => {
                    if !handle_line(&mut session, &mut decoder, &ctx.sink, &line).await {
                        break;
                    }
                }
                Ok(None) => break,
                Err(err) => {
                    ctx.sink.fail(ErrorKind::Protocol, format!("cannot read the CLI: {err}"), true);
                    break;
                }
            },
            command = inbox.recv() => match command {
                Some(command) => {
                    if !handle_command(&mut session, &mut decoder, command, &mut interrupts).await {
                        break;
                    }
                }
                None => break,
            },
        }
    }

    finish(session, decoder, ctx).await;
}

/// Decode one CLI line, emit what it produced, and answer what it asked.
async fn handle_line(
    session: &mut Session,
    decoder: &mut StreamDecoder,
    sink: &EventSink,
    line: &str,
) -> bool {
    if line.trim().is_empty() {
        return true;
    }
    let produced = decoder.push(line);
    for body in produced.events {
        if !sink.emit(body) {
            return false;
        }
    }
    for reply in produced.replies {
        if !session.write(&reply).await {
            return false;
        }
    }
    true
}

/// Act on one command from the daemon.
async fn handle_command(
    session: &mut Session,
    decoder: &mut StreamDecoder,
    command: BackendCommand,
    interrupts: &mut u32,
) -> bool {
    match command {
        BackendCommand::Send { blocks } => session.write(&user_message(&blocks)).await,
        BackendCommand::Interrupt => {
            *interrupts = interrupts.saturating_add(1);
            session
                .write(&json!({
                    "type": "control_request",
                    "request_id": format!("req_{interrupts}_interrupt"),
                    "request": {"subtype": "interrupt"},
                }))
                .await
        }
        BackendCommand::Permission {
            request,
            decision,
            // The CLI owns the rule store on this path. It resolves one call
            // at a time through the control envelope and there is nothing in
            // that protocol for a rule this daemon would write, so `forever`
            // means the same thing as `once` here.
            scope: _,
            updated_input,
            message,
        } => {
            // A request the CLI withdrew must not be answered late. Section 5
            // says so and the decoder is the thing that knows, because it saw
            // the control_cancel_request.
            if !decoder.is_open(&request) {
                tracing::debug!(request, "dropping a decision for a withdrawn request");
                return true;
            }
            decoder.close(&request);
            session
                .write(&permission_response(
                    &request,
                    decision,
                    updated_input,
                    message,
                ))
                .await
        }
        BackendCommand::Shutdown => false,
    }
}

/// Close the child down and report anything left open.
///
/// A child that ends with a turn still running is a `backend_spawn` failure,
/// which is the kind the scope table gives to a backend that "died
/// mid-turn". A child that ends between turns is the ordinary shutdown path
/// and says nothing.
async fn finish(mut session: Session, decoder: StreamDecoder, ctx: BackendContext) {
    drop(session.stdin);
    let status = session.child.wait().await;
    if decoder.turn_open {
        let detail = match status {
            Ok(status) => format!("the claude CLI exited with {status} while a turn was running"),
            Err(err) => format!("the claude CLI could not be reaped: {err}"),
        };
        ctx.sink.fail(ErrorKind::BackendSpawn, detail, true);
        ctx.sink.emit(EventBody::TurnEnd {
            turn: None,
            stop: StopReason::Error,
            text: None,
            duration_ms: 0,
        });
    }
}

/// Forward the child's stderr to the journal.
///
/// Not to the pane. The CLI writes progress chatter and node warnings here
/// as well as real failures, and nothing in the bytes separates the two, so
/// turning every line into an `error` event would fill the pane with noise.
/// A failure that matters shows up as a non-zero exit, which [`finish`]
/// reports, or as a `result` line the decoder already turns into an event.
async fn drain_stderr(stderr: tokio::process::ChildStderr, conversation: Uuid) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if !line.trim().is_empty() {
            tracing::warn!(conversation = %conversation, line, "claude stderr");
        }
    }
}

/// One user message, in the shape the CLI's stdin takes.
///
/// Attachments travel as paths in this protocol and the CLI has no block
/// type for a path, so a file block becomes a line of text naming it. That
/// is honest: the model can then `Read` the file itself, gated by the same
/// permission prompt every other read gets.
#[must_use]
pub fn user_message(blocks: &[SendBlock]) -> Value {
    let content: Vec<Value> = blocks
        .iter()
        .map(|block| match block.kind {
            BlockKind::Text => json!({
                "type": "text",
                "text": block.text.clone().unwrap_or_default(),
            }),
            BlockKind::Image | BlockKind::File => json!({
                "type": "text",
                "text": format!(
                    "[attached {}: {}]",
                    block.kind,
                    block.path.as_ref().map_or_else(String::new, |path| path.display().to_string()),
                ),
            }),
        })
        .collect();
    json!({
        "type": "user",
        "message": {"role": "user", "content": content},
    })
}

/// The `control_response` that answers one `can_use_tool`.
///
/// A denial is still a `success` control response; `behavior` carries the
/// verdict. `updatedInput` is omitted rather than sent as null when the user
/// did not edit the arguments, because the bundle resolves it as
/// `("updatedInput" in e ? e.updatedInput : void 0) ?? original` and a null
/// would work by accident rather than by contract.
#[must_use]
pub fn permission_response(
    request: &str,
    decision: PermissionDecision,
    updated_input: Option<Value>,
    message: Option<String>,
) -> Value {
    let response = match decision {
        PermissionDecision::Allow => {
            let mut allow = json!({"behavior": "allow"});
            if let (Some(input), Some(object)) = (updated_input, allow.as_object_mut()) {
                object.insert("updatedInput".to_owned(), input);
            }
            allow
        }
        PermissionDecision::Deny => json!({
            "behavior": "deny",
            "message": message.unwrap_or_else(|| "denied from the ask pane".to_owned()),
            "interrupt": false,
        }),
    };
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": request,
            "response": response,
        },
    })
}

/// What one decoded line produced.
#[derive(Debug, Default)]
pub struct Decoded {
    /// Normalized events, with `turn: None` for `Session::adopt` to fill in.
    pub events: Vec<EventBody>,
    /// Lines to write back to the CLI's stdin.
    pub replies: Vec<Value>,
}

/// One open assistant content block, tracked so `content_block_stop` can
/// settle it.
///
/// A `tool_use` block's id is deliberately not kept. The settled `assistant`
/// line carries both the id and the arguments, and the fixture shows it
/// always arrives, so keeping a second copy here would be a second thing to
/// go stale.
#[derive(Debug, Clone)]
struct OpenBlock {
    /// What the block is, from `content_block_start`.
    kind: String,
    /// Everything the deltas appended, for the code-block scan at stop.
    text: String,
}

/// The stream-json decoder, which is the whole of section 1 in one type.
///
/// It holds no I/O, which is what lets `tests/claude_code.rs` drive it
/// straight off the recorded fixture with no process and no network.
#[derive(Debug)]
pub struct StreamDecoder {
    /// The model the thread was created with, until `system/init` names the
    /// resolved one.
    model: Option<String>,
    /// Whether a turn is open, so `finish` can tell a mid-turn death from a
    /// clean exit.
    pub turn_open: bool,
    /// Open content blocks by their stream index.
    blocks: BTreeMap<u32, OpenBlock>,
    /// Permission requests the CLI has asked and not withdrawn.
    open_requests: BTreeMap<String, String>,
    /// The arguments of each tool call, kept so a `diff` can be reshaped
    /// from them when the result carries no usable patch.
    tool_inputs: BTreeMap<String, Value>,
    /// The running thinking-token estimate from `system/thinking_tokens`.
    thinking_tokens: Option<u32>,
    /// The last `rate_limit_event`, folded into the turn's `usage`.
    rate_limit: Option<crate::proto::RateLimit>,
}

impl StreamDecoder {
    /// A decoder for a thread created with `model`.
    #[must_use]
    pub fn new(model: Option<String>) -> Self {
        Self {
            model,
            turn_open: false,
            blocks: BTreeMap::new(),
            open_requests: BTreeMap::new(),
            tool_inputs: BTreeMap::new(),
            thinking_tokens: None,
            rate_limit: None,
        }
    }

    /// Whether a permission request is still waiting for an answer.
    #[must_use]
    pub fn is_open(&self, request: &str) -> bool {
        self.open_requests.contains_key(request)
    }

    /// Forget a permission request that has been answered.
    pub fn close(&mut self, request: &str) {
        self.open_requests.remove(request);
    }

    /// Decode one line of the CLI's stdout.
    ///
    /// A line that is not JSON, or that is JSON this build has no branch
    /// for, produces a `protocol` error rather than being dropped. A silent
    /// drop after a CLI upgrade is exactly the failure the fixture test
    /// exists to catch, and the same reasoning applies at runtime.
    pub fn push(&mut self, line: &str) -> Decoded {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return Decoded {
                events: vec![protocol_error(format!(
                    "the claude CLI wrote a line that is not JSON: {}",
                    truncate(line, 200)
                ))],
                replies: Vec::new(),
            };
        };
        match value.get("type").and_then(Value::as_str) {
            Some("system") => self.system(&value),
            Some("stream_event") => self.stream_event(&value),
            Some("assistant") => self.assistant(&value),
            Some("user") => self.user(&value),
            Some("rate_limit_event") => {
                self.rate_limit = rate_limit(&value);
                Decoded::default()
            }
            Some("control_request") => self.control_request(&value),
            Some("control_cancel_request") => self.control_cancel(&value),
            // The initialize and interrupt replies. Nothing in either is
            // acted on, and both are expected, so neither is an error.
            Some("control_response") => Decoded::default(),
            Some("result") => self.result(&value),
            other => Decoded {
                events: vec![protocol_error(format!(
                    "the claude CLI sent an unknown line type {other:?}"
                ))],
                replies: Vec::new(),
            },
        }
    }

    /// `system/*`: only `init` and `thinking_tokens` say anything the schema
    /// carries.
    fn system(&mut self, value: &Value) -> Decoded {
        match value.get("subtype").and_then(Value::as_str) {
            Some("init") => {
                // The turn opens here. init is emitted once per user turn,
                // which the fixture shows three times on one session_id.
                if let Some(model) = value.get("model").and_then(Value::as_str) {
                    self.model = Some(model.to_owned());
                }
                self.turn_open = true;
                self.blocks.clear();
                self.thinking_tokens = None;
                Decoded {
                    events: vec![EventBody::TurnStart {
                        turn: None,
                        backend: CLAUDE_CODE.to_owned(),
                        model: self.model.clone(),
                        started_ms: crate::server::now_ms(),
                    }],
                    replies: Vec::new(),
                }
            }
            Some("thinking_tokens") => {
                self.thinking_tokens = value
                    .get("estimated_tokens")
                    .and_then(Value::as_u64)
                    .and_then(|tokens| u32::try_from(tokens).ok());
                Decoded::default()
            }
            Some("permission_denied") => Decoded {
                // Only reachable when --permission-prompt-tool is missing,
                // which this backend always passes. Saying so beats a silent
                // auto-deny that looks like the model refusing.
                events: vec![protocol_error(
                    "the CLI denied a tool itself, which means --permission-prompt-tool did not take effect".to_owned(),
                )],
                replies: Vec::new(),
            },
            // status, hook_started and hook_response have no event in the
            // schema and the pane has no surface for them.
            _ => Decoded::default(),
        }
    }

    /// `stream_event/*`: the incremental half of a message.
    fn stream_event(&mut self, value: &Value) -> Decoded {
        let Some(event) = value.get("event") else {
            return Decoded::default();
        };
        match event.get("type").and_then(Value::as_str) {
            Some("content_block_start") => self.block_start(event),
            Some("content_block_delta") => self.block_delta(event),
            Some("content_block_stop") => self.block_stop(event),
            Some("message_delta") => Decoded {
                events: usage_event(event.get("usage"), None, self.rate_limit.clone())
                    .into_iter()
                    .collect(),
                replies: Vec::new(),
            },
            // message_start carries ttft_ms and an empty content list;
            // message_stop carries nothing. Neither has an event.
            _ => Decoded::default(),
        }
    }

    /// A content block opened.
    fn block_start(&mut self, event: &Value) -> Decoded {
        let index = block_index(event);
        let block = event.get("content_block");
        let kind = block
            .and_then(|block| block.get("type"))
            .and_then(Value::as_str)
            .unwrap_or("text")
            .to_owned();
        self.blocks.insert(
            index,
            OpenBlock {
                kind,
                text: String::new(),
            },
        );
        Decoded::default()
    }

    /// A content block grew.
    fn block_delta(&mut self, event: &Value) -> Decoded {
        let index = block_index(event);
        let Some(delta) = event.get("delta") else {
            return Decoded::default();
        };
        match delta.get("type").and_then(Value::as_str) {
            Some("text_delta") => {
                let text = delta
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                if let Some(block) = self.blocks.get_mut(&index) {
                    block.text.push_str(&text);
                }
                Decoded {
                    events: vec![EventBody::TextDelta {
                        turn: None,
                        block: index,
                        text,
                    }],
                    replies: Vec::new(),
                }
            }
            Some("thinking_delta") => {
                // Always the empty string on this harness. The only real
                // signal is the token estimate, which is why the pane must
                // treat an empty thinking block as normal.
                let tokens = delta
                    .get("estimated_tokens")
                    .and_then(Value::as_u64)
                    .and_then(|tokens| u32::try_from(tokens).ok())
                    .or(self.thinking_tokens);
                Decoded {
                    events: vec![EventBody::ThinkingDelta {
                        turn: None,
                        block: index,
                        text: delta
                            .get("thinking")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned(),
                        tokens,
                    }],
                    replies: Vec::new(),
                }
            }
            // signature_delta is the thinking block's cryptographic
            // signature and input_json_delta is the settled assistant line's
            // job. Neither has an event.
            _ => Decoded::default(),
        }
    }

    /// A content block closed. This is where the code-block scan runs.
    fn block_stop(&mut self, event: &Value) -> Decoded {
        let index = block_index(event);
        let Some(block) = self.blocks.remove(&index) else {
            return Decoded::default();
        };
        if block.kind != "text" {
            return Decoded::default();
        }
        let events = render::code_blocks(&block.text)
            .into_iter()
            .map(|code| EventBody::CodeBlock {
                turn: None,
                block: index,
                html: Some(render::code_block_html(&code.source, code.language.as_deref())),
                language: code.language,
                source: code.source,
            })
            .collect();
        Decoded {
            events,
            replies: Vec::new(),
        }
    }

    /// The settled form of one content block.
    ///
    /// One line per block regardless of what the blocks are, which the
    /// fixture proves: ten `assistant` lines across seven messages, three
    /// `message.id` values appearing twice. The line is not a cumulative
    /// snapshot, so only the first content entry is read.
    fn assistant(&mut self, value: &Value) -> Decoded {
        let Some(block) = value
            .pointer("/message/content/0")
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
        else {
            return Decoded::default();
        };
        let Some(call) = block.get("id").and_then(Value::as_str) else {
            return Decoded::default();
        };
        let name = block
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let input = block.get("input").cloned().unwrap_or(Value::Null);
        self.tool_inputs.insert(call.to_owned(), input.clone());

        let mut events = vec![EventBody::ToolCall {
            turn: None,
            call: call.to_owned(),
            display_name: Some(name.clone()),
            summary: tool_summary(&name, &input),
            name,
            input,
            origin: ToolOrigin::Harness,
        }];
        // ExitPlanMode is how the harness proposes a plan, and its input is
        // the plan itself.
        if let Some(plan) = plan_event(block) {
            events.push(plan);
        }
        Decoded {
            events,
            replies: Vec::new(),
        }
    }

    /// A `user` line, which is either a tool result or the interrupt notice.
    fn user(&mut self, value: &Value) -> Decoded {
        let Some(result) = value
            .pointer("/message/content/0")
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_result"))
        else {
            // Line 130 of the fixture: a plain text block with no
            // tool_use_id, which is the CLI's own interrupt notice. The
            // daemon raises its own turn_end for that, so this says nothing.
            return Decoded::default();
        };
        let Some(call) = result.get("tool_use_id").and_then(Value::as_str) else {
            return Decoded::default();
        };
        // A missing is_error means success. Only the two non-execution paths
        // set it, and only ever to true.
        let ok = !result
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let content = result
            .get("content")
            .map_or_else(String::new, |content| match content {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            });
        let truncated = content.len() > MAX_TOOL_RESULT;

        // A tool that ran answered whatever gated it, so a request still
        // open on the same call is finished.
        self.open_requests.retain(|_, gated| gated != call);

        let mut events = vec![EventBody::ToolResult {
            call: call.to_owned(),
            ok,
            content: truncate(&content, MAX_TOOL_RESULT),
            truncated,
        }];
        if ok {
            events.extend(self.diff_event(call, value.get("tool_use_result")));
        }
        Decoded {
            events,
            replies: Vec::new(),
        }
    }

    /// The `diff` for one successful file-writing tool.
    ///
    /// The CLI emits no `diff` event of its own, so the daemon always builds
    /// it. `tool_use_result.structuredPatch` would be the better source and
    /// is the branch the spec names first, but the fixture holds exactly one
    /// and it is empty, because `Write` on a file that did not exist has
    /// nothing to diff against. So a non-empty `structuredPatch` was never
    /// observed, nothing defines the shape of one of its elements, and only
    /// the second branch is built here: the file's own before and after.
    fn diff_event(&self, call: &str, tool_use_result: Option<&Value>) -> Option<EventBody> {
        let result = tool_use_result?.as_object()?;
        let path = result.get("filePath").and_then(Value::as_str)?;
        let new_text = result
            .get("content")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                self.tool_inputs
                    .get(call)?
                    .get("content")?
                    .as_str()
                    .map(str::to_owned)
            })?;
        let old_text = result
            .get("originalFile")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (added, removed) = render::diff_line_counts(old_text, &new_text);
        Some(EventBody::Diff {
            call: call.to_owned(),
            path: PathBuf::from(path),
            html: Some(render::diff_html(old_text, &new_text)),
            old_text: old_text.to_owned(),
            new_text,
            added,
            removed,
        })
    }

    /// A control request from the CLI.
    fn control_request(&mut self, value: &Value) -> Decoded {
        let Some(request_id) = value.get("request_id").and_then(Value::as_str) else {
            return Decoded {
                events: vec![protocol_error(
                    "a control_request arrived with no request_id".to_owned(),
                )],
                replies: Vec::new(),
            };
        };
        let request = value.get("request").unwrap_or(&Value::Null);
        match request.get("subtype").and_then(Value::as_str) {
            Some("can_use_tool") => self.can_use_tool(request_id, request),
            other => {
                // An unanswered control request stalls the turn with no
                // visible cause, and the CLI can send three subtypes. Only
                // can_use_tool was ever exercised, so the other two are
                // refused explicitly rather than ignored.
                let subtype = other.unwrap_or("<none>").to_owned();
                Decoded {
                    events: vec![protocol_error(format!(
                        "the CLI sent a {subtype:?} control request, which dots-ask does not implement; it was refused so the turn does not stall"
                    ))],
                    replies: vec![json!({
                        "type": "control_response",
                        "response": {
                            "subtype": "success",
                            "request_id": request_id,
                            "response": {
                                "behavior": "deny",
                                "message": format!("dots-ask does not implement the {subtype:?} control subtype"),
                                "interrupt": false,
                            },
                        },
                    })],
                }
            }
        }
    }

    /// A `can_use_tool` request, which becomes a `permission_request`.
    fn can_use_tool(&mut self, request_id: &str, request: &Value) -> Decoded {
        let call = request
            .get("tool_use_id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let name = request
            .get("tool_name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        self.open_requests.insert(request_id.to_owned(), call.clone());
        Decoded {
            events: vec![EventBody::PermissionRequest {
                request: request_id.to_owned(),
                call,
                name,
                display_name: request
                    .get("display_name")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                description: request
                    .get("description")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                input: request.get("input").cloned().unwrap_or(Value::Null),
                suggestions: request
                    .get("permission_suggestions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
                withdrawn: false,
            }],
            replies: Vec::new(),
        }
    }

    /// The CLI withdrew a permission request.
    ///
    /// The event goes out again with `withdrawn: true`, which is what tells
    /// the pane to dismiss the prompt, and the request leaves the open table
    /// so a decision that arrives afterwards is dropped rather than written
    /// back to a CLI that is no longer waiting.
    fn control_cancel(&mut self, value: &Value) -> Decoded {
        let Some(request_id) = value.get("request_id").and_then(Value::as_str) else {
            return Decoded::default();
        };
        let Some(call) = self.open_requests.remove(request_id) else {
            return Decoded::default();
        };
        Decoded {
            events: vec![EventBody::PermissionRequest {
                request: request_id.to_owned(),
                call,
                name: String::new(),
                display_name: None,
                description: None,
                input: Value::Null,
                suggestions: Vec::new(),
                withdrawn: true,
            }],
            replies: Vec::new(),
        }
    }

    /// A `result` line: the end of one user turn, not of the session.
    ///
    /// The process stays alive on the same `session_id`, which the fixture
    /// shows three times over, so this closes the turn and nothing else.
    fn result(&mut self, value: &Value) -> Decoded {
        self.turn_open = false;
        self.open_requests.clear();
        let terminal = value
            .get("terminal_reason")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let stop = stop_reason(value, terminal);
        let mut events = Vec::new();
        if let Some(usage) = usage_event(
            value.get("usage"),
            value.get("total_cost_usd").and_then(Value::as_f64),
            self.rate_limit.clone(),
        ) {
            events.push(usage);
        }
        // The CLI marks a client interrupt as a failure. The daemon does
        // not: the client asked for it, so turn_end carries
        // stop: "interrupted" and no error goes with it.
        if stop == StopReason::Error {
            let detail = value
                .get("errors")
                .and_then(Value::as_array)
                .map(|errors| {
                    errors
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join("; ")
                })
                .filter(|text| !text.is_empty())
                .unwrap_or_else(|| {
                    value
                        .get("subtype")
                        .and_then(Value::as_str)
                        .unwrap_or("the turn failed")
                        .to_owned()
                });
            events.push(EventBody::Error {
                kind: ErrorKind::Protocol,
                message: detail,
                fatal: false,
            });
        }
        events.push(EventBody::TurnEnd {
            turn: None,
            stop,
            text: value
                .get("result")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .filter(|_| stop != StopReason::Interrupted),
            duration_ms: 0,
        });
        Decoded {
            events,
            replies: Vec::new(),
        }
    }
}

/// The `stop` for one `result` line.
///
/// `terminal_reason` decides first, and `subtype` plus `stop_reason` only
/// when it does not. A decoder that reads `is_error` without checking
/// `terminal_reason` reports the fixture's own third turn as a failure.
#[must_use]
fn stop_reason(value: &Value, terminal: &str) -> StopReason {
    match terminal {
        "aborted_tools" | "aborted" | "interrupted" => return StopReason::Interrupted,
        "max_tokens" => return StopReason::MaxTokens,
        _ => {}
    }
    if value.get("is_error").and_then(Value::as_bool) == Some(true) {
        return StopReason::Error;
    }
    match value.get("stop_reason").and_then(Value::as_str) {
        Some("tool_use") => StopReason::ToolUse,
        Some("max_tokens") => StopReason::MaxTokens,
        _ => StopReason::EndTurn,
    }
}

/// The `usage` event for one `usage` object, when it carries anything.
fn usage_event(
    usage: Option<&Value>,
    cost_usd: Option<f64>,
    rate_limit: Option<crate::proto::RateLimit>,
) -> Option<EventBody> {
    let usage = usage?;
    Some(EventBody::Usage {
        turn: None,
        input_tokens: usage.get("input_tokens").and_then(Value::as_u64)?,
        output_tokens: usage
            .get("output_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        cache_read_tokens: usage.get("cache_read_input_tokens").and_then(Value::as_u64),
        cache_write_tokens: usage
            .get("cache_creation_input_tokens")
            .and_then(Value::as_u64),
        thinking_tokens: usage
            .pointer("/output_tokens_details/thinking_tokens")
            .and_then(Value::as_u64),
        cost_usd,
        rate_limit,
    })
}

/// The `RateLimit` off one `rate_limit_event` line.
fn rate_limit(value: &Value) -> Option<crate::proto::RateLimit> {
    let info = value.get("rate_limit_info")?;
    Some(crate::proto::RateLimit {
        kind: info.get("rateLimitType").and_then(Value::as_str)?.to_owned(),
        status: info
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        resets_at: info.get("resetsAt").and_then(Value::as_u64).unwrap_or(0),
    })
}

/// The `plan` event for an `ExitPlanMode` call, when that is what this is.
fn plan_event(block: &Value) -> Option<EventBody> {
    if block.get("name").and_then(Value::as_str) != Some("ExitPlanMode") {
        return None;
    }
    let markdown = block
        .pointer("/input/plan")
        .and_then(Value::as_str)?
        .to_owned();
    Some(EventBody::Plan {
        turn: None,
        title: None,
        markdown,
        state: crate::proto::PlanState::Proposed,
    })
}

/// A one-line summary of a tool call, for the pane's collapsed row.
///
/// Only the arguments the harness tools actually carry, and nothing
/// invented: a tool with none gets `None` and the pane shows the name alone.
fn tool_summary(name: &str, input: &Value) -> Option<String> {
    let key = match name {
        "Write" | "Edit" | "Read" | "NotebookEdit" => "file_path",
        "Bash" => "command",
        "WebFetch" => "url",
        "WebSearch" | "Grep" => "query",
        "Glob" => "pattern",
        _ => return None,
    };
    input
        .get(key)
        .and_then(Value::as_str)
        .map(|text| truncate(text, 120))
}

/// The stream index of one content block event.
fn block_index(event: &Value) -> u32 {
    event
        .get("index")
        .and_then(Value::as_u64)
        .and_then(|index| u32::try_from(index).ok())
        .unwrap_or(0)
}

/// A conversation-scoped `protocol` error, never fatal.
///
/// The decoder failing on one line does not kill the thread: the CLI is
/// still running and the next line may well be one this build understands.
fn protocol_error(message: String) -> EventBody {
    EventBody::Error {
        kind: ErrorKind::Protocol,
        message,
        fatal: false,
    }
}

/// Cut a string to `limit` bytes on a character boundary.
fn truncate(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}
