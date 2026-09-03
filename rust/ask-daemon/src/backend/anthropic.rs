//! The Anthropic Messages API: `POST /v1/messages` with SSE.
//!
//! The same block-and-delta structure the harness carries, one layer down.
//! `content_block_start` opens a block, `content_block_delta` grows it and
//! `content_block_stop` closes it, exactly as in section 1, which is why
//! this adapter and `claude_code.rs` produce the same normalized events from
//! visibly different bytes.
//!
//! Two things differ from the harness and both matter to the pane.
//!
//! **Thinking carries real text here**, and only when the request turns
//! extended thinking on. The harness sends the block structure with an empty
//! string and a token estimate. So `thinking_delta.text` may be empty or
//! full depending on the backend, and the pane must treat either as normal.
//!
//! **The tool arguments stream.** A `tool_use` block opens with an empty
//! input and the arguments arrive as `input_json_delta` fragments that only
//! parse once the last one lands, which is why [`PendingToolCall`] holds
//! them as text.
//!
//! `cost_usd` is computed here from a static price table, because the API
//! reports tokens and never a price. A model the table does not know gets
//! `null` rather than a guess.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::backend::provider::{self, ChunkDecoder, PendingToolCall, ProviderSession, TurnRequest};
use crate::backend::{
    unavailable, Backend, BackendCommand, BackendContext, BackendHandle, LineBuffer, SseDecoder,
    ANTHROPIC,
};
use crate::proto::{BackendInfo, BackendState, ErrorKind, EventBody, StopReason};
use crate::secrets::{Secret, SecretStore};

/// The endpoint, unless `DOTS_ASK_ANTHROPIC_URL` says otherwise.
const DEFAULT_BASE_URL: &str = "https://api.anthropic.com";

/// The variable that moves it, which is what points a test at a local fake.
const BASE_URL_VAR: &str = "DOTS_ASK_ANTHROPIC_URL";

/// The keyring attribute the API key is stored under.
pub const KEY_ATTRIBUTE: &str = "anthropic-api-key";

/// The API version header the Messages API requires.
const API_VERSION: &str = "2023-06-01";

/// The models the pane offers.
const MODELS: [&str; 3] = ["claude-opus-4-1", "claude-sonnet-4-5", "claude-haiku-4-5"];

/// The default when a thread names no model.
const DEFAULT_MODEL: &str = "claude-sonnet-4-5";

/// How many output tokens one turn may produce.
const MAX_TOKENS: u64 = 8192;

/// Dollars per million tokens, input then output, per model.
///
/// Static because the API reports tokens and never a price, and a table is
/// the only way to fill `usage.cost_usd` at all. A model that is not here
/// gets `null`, which the schema allows and which is honest: a wrong number
/// on a cost display is worse than no number.
const PRICES: [(&str, f64, f64); 3] = [
    ("claude-opus-4-1", 15.0, 75.0),
    ("claude-sonnet-4-5", 3.0, 15.0),
    ("claude-haiku-4-5", 1.0, 5.0),
];

/// The Anthropic Messages API.
pub struct AnthropicBackend {
    base_url: String,
}

impl AnthropicBackend {
    /// Read the endpoint out of the environment.
    ///
    /// Deliberately not a probe. Availability here is decided by a keyring
    /// key, and reading one at startup is what `secrets.rs` exists to
    /// prevent, so this touches nothing.
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            base_url: std::env::var(BASE_URL_VAR).unwrap_or_else(|_| DEFAULT_BASE_URL.to_owned()),
        }
    }

    /// A backend pinned to one base url.
    #[must_use]
    pub fn at(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
        }
    }
}

impl Backend for AnthropicBackend {
    fn id(&self) -> &'static str {
        ANTHROPIC
    }

    fn info(&self, secrets: &SecretStore) -> BackendInfo {
        // Only the cached answer, never a fresh lookup. A lookup here would
        // run before the socket is bound and could block for ten seconds on
        // a locked keyring, which is exactly the cold-boot hang the module
        // header of secrets.rs is about.
        match secrets.cached(KEY_ATTRIBUTE) {
            Some(Secret::Found(_)) => BackendInfo {
                id: ANTHROPIC.to_owned(),
                label: "Anthropic API".to_owned(),
                state: BackendState::Ready,
                models: MODELS.iter().map(|name| (*name).to_owned()).collect(),
                detail: None,
            },
            Some(Secret::Missing(reason)) => unavailable(ANTHROPIC, "Anthropic API", reason),
            None => unavailable(
                ANTHROPIC,
                "Anthropic API",
                format!(
                    "the API key is read from the login keyring ({KEY_ATTRIBUTE}) on the first send, never at startup"
                ),
            ),
        }
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let (commands, inbox) = mpsc::unbounded_channel();
        let model = ctx
            .model
            .clone()
            .unwrap_or_else(|| DEFAULT_MODEL.to_owned());
        let secrets = Arc::clone(&ctx.secrets);
        let session = ProviderSession::new(&ctx, ANTHROPIC);
        let url = format!("{}/v1/messages", self.base_url);
        tokio::spawn(run(session, url, model, secrets, inbox));
        Ok(BackendHandle::new(commands))
    }
}

/// Serve one thread until its command channel closes.
async fn run(
    mut session: ProviderSession,
    url: String,
    model: String,
    secrets: Arc<SecretStore>,
    mut inbox: mpsc::UnboundedReceiver<BackendCommand>,
) {
    while let Some(command) = inbox.recv().await {
        match command {
            BackendCommand::Send { blocks } => {
                // The keyring is read here, on the first send, and never at
                // startup. A missing key ends the thread rather than hanging
                // it, and says which attribute to store.
                let Secret::Found(key) = secrets.lookup(KEY_ATTRIBUTE).await else {
                    let detail = secrets
                        .cached(KEY_ATTRIBUTE)
                        .and_then(|secret| secret.detail().map(str::to_owned))
                        .unwrap_or_else(|| "no Anthropic API key in the login keyring".to_owned());
                    session.sink.fail(ErrorKind::Auth, detail, true);
                    break;
                };
                session.push_user(&blocks);
                let tools = provider::tool_schemas(&Arc::clone(&session.mcp)).await;
                let request = request(&url, &key, &model, tools);
                if !session
                    .run_turn::<AnthropicDecoder>(Some(&model), &request, &mut inbox)
                    .await
                {
                    break;
                }
            }
            BackendCommand::Interrupt => session.interrupt(),
            BackendCommand::Permission {
                request,
                decision,
                scope,
                updated_input,
                message,
            } => session.answer(request, decision, scope, updated_input, message),
            BackendCommand::Shutdown => break,
        }
    }
}

/// The `/v1/messages` request, plus how a tool result rejoins the history.
///
/// Public so `tests/provider.rs` can drive the real turn loop against a fake
/// server rather than a re-implementation of this shape.
pub fn request(url: &str, key: &str, model: &str, tools: Vec<Value>) -> TurnRequest {
    let model = model.to_owned();
    TurnRequest {
        url: url.to_owned(),
        headers: vec![
            ("x-api-key".to_owned(), key.to_owned()),
            ("anthropic-version".to_owned(), API_VERSION.to_owned()),
        ],
        build: Box::new(move |messages| {
            let mut body = json!({
                "model": model,
                "max_tokens": MAX_TOKENS,
                "messages": messages,
                "stream": true,
            });
            if !tools.is_empty() {
                if let Some(object) = body.as_object_mut() {
                    // The Messages API takes a flat tool list rather than
                    // the OpenAI function wrapper, so the shared schemas are
                    // unwrapped here.
                    object.insert(
                        "tools".to_owned(),
                        Value::Array(tools.iter().map(unwrap_function).collect()),
                    );
                }
            }
            body
        }),
        record_result: Box::new(|call, ok, content| {
            json!({
                "role": "user",
                "content": [{
                    "type": "tool_result",
                    "tool_use_id": call.id,
                    "content": content,
                    "is_error": !ok,
                }],
            })
        }),
    }
}

/// Turn an OpenAI-shaped function schema into the Messages API's own.
fn unwrap_function(tool: &Value) -> Value {
    let function = tool.get("function").unwrap_or(tool);
    json!({
        "name": function.get("name").cloned().unwrap_or(Value::Null),
        "description": function.get("description").cloned().unwrap_or(Value::Null),
        "input_schema": function.get("parameters").cloned().unwrap_or(json!({"type": "object"})),
    })
}

/// The SSE decoder for the Messages API.
#[derive(Debug)]
pub struct AnthropicDecoder {
    lines: LineBuffer,
    sse: SseDecoder,
    /// Open `tool_use` blocks by stream index, so `input_json_delta`
    /// fragments land on the right call.
    tools: BTreeMap<u32, PendingToolCall>,
    finished: Vec<PendingToolCall>,
    text: String,
    stop: StopReason,
    /// Input tokens off `message_start`, which is the only place they
    /// appear; `message_delta` carries the output count.
    input_tokens: u64,
    cache_read: Option<u64>,
    cache_write: Option<u64>,
    model: Option<String>,
}

impl Default for AnthropicDecoder {
    fn default() -> Self {
        Self {
            lines: LineBuffer::default(),
            sse: SseDecoder::default(),
            tools: BTreeMap::new(),
            finished: Vec::new(),
            text: String::new(),
            stop: StopReason::EndTurn,
            input_tokens: 0,
            cache_read: None,
            cache_write: None,
            model: None,
        }
    }
}

impl ChunkDecoder for AnthropicDecoder {
    fn push(&mut self, chunk: &str) -> Vec<EventBody> {
        let mut events = Vec::new();
        for line in self.lines.push(chunk) {
            if let Some(frame) = self.sse.push(&line) {
                events.extend(self.frame(&frame.data));
            }
        }
        events
    }

    fn finish(&mut self) -> Vec<EventBody> {
        let mut events = Vec::new();
        if let Some(line) = self.lines.finish() {
            if let Some(frame) = self.sse.push(&line) {
                events.extend(self.frame(&frame.data));
            }
        }
        events.extend(provider::code_block_events(&self.text, 0));
        events
    }

    fn take_tool_calls(&mut self) -> Vec<PendingToolCall> {
        let mut calls = std::mem::take(&mut self.finished);
        calls.extend(std::mem::take(&mut self.tools).into_values());
        calls
    }

    fn stop(&self) -> StopReason {
        self.stop
    }

    fn take_text(&mut self) -> String {
        std::mem::take(&mut self.text)
    }
}

impl AnthropicDecoder {
    /// Decode one SSE frame's data payload.
    fn frame(&mut self, data: &str) -> Vec<EventBody> {
        if data.trim().is_empty() {
            return Vec::new();
        }
        let Ok(value) = serde_json::from_str::<Value>(data) else {
            return vec![provider::protocol_error(format!(
                "the Messages API sent a data frame that is not JSON: {}",
                provider::truncate(data, 200)
            ))];
        };
        match value.get("type").and_then(Value::as_str) {
            Some("message_start") => {
                self.message_start(&value);
                Vec::new()
            }
            Some("content_block_start") => {
                self.block_start(&value);
                Vec::new()
            }
            Some("content_block_delta") => self.block_delta(&value),
            Some("content_block_stop") => {
                self.block_stop(&value);
                Vec::new()
            }
            Some("message_delta") => self.message_delta(&value),
            Some("error") => {
                self.stop = StopReason::Error;
                vec![provider::api_error(
                    value
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("the Messages API reported an error")
                        .to_owned(),
                )]
            }
            // ping and message_stop say nothing the schema carries.
            _ => Vec::new(),
        }
    }

    /// The message opened, which is where the input counts live.
    fn message_start(&mut self, value: &Value) {
        self.model = value
            .pointer("/message/model")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let usage = value.pointer("/message/usage");
        self.input_tokens = usage
            .and_then(|usage| usage.get("input_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        self.cache_read = usage
            .and_then(|usage| usage.get("cache_read_input_tokens"))
            .and_then(Value::as_u64);
        self.cache_write = usage
            .and_then(|usage| usage.get("cache_creation_input_tokens"))
            .and_then(Value::as_u64);
    }

    /// A content block opened.
    fn block_start(&mut self, value: &Value) {
        let index = index_of(value);
        let block = value.get("content_block");
        if block
            .and_then(|block| block.get("type"))
            .and_then(Value::as_str)
            != Some("tool_use")
        {
            return;
        }
        self.tools.insert(
            index,
            PendingToolCall {
                id: block
                    .and_then(|block| block.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                name: block
                    .and_then(|block| block.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                arguments: String::new(),
            },
        );
    }

    /// A content block grew.
    fn block_delta(&mut self, value: &Value) -> Vec<EventBody> {
        let index = index_of(value);
        let Some(delta) = value.get("delta") else {
            return Vec::new();
        };
        match delta.get("type").and_then(Value::as_str) {
            Some("text_delta") => {
                let text = delta
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                self.text.push_str(&text);
                vec![EventBody::TextDelta {
                    turn: None,
                    block: index,
                    text,
                }]
            }
            Some("thinking_delta") => vec![EventBody::ThinkingDelta {
                turn: None,
                block: index,
                // Real text here, unlike the harness, and only when the
                // request enabled extended thinking.
                text: delta
                    .get("thinking")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                tokens: None,
            }],
            Some("input_json_delta") => {
                if let Some(call) = self.tools.get_mut(&index) {
                    call.arguments.push_str(
                        delta
                            .get("partial_json")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                    );
                }
                Vec::new()
            }
            // signature_delta is the thinking block's signature.
            _ => Vec::new(),
        }
    }

    /// A content block closed, which settles any tool call it held.
    fn block_stop(&mut self, value: &Value) {
        if let Some(call) = self.tools.remove(&index_of(value)) {
            self.finished.push(call);
        }
    }

    /// The message's own delta, which carries the stop reason and the output
    /// counts.
    fn message_delta(&mut self, value: &Value) -> Vec<EventBody> {
        self.stop = match value.pointer("/delta/stop_reason").and_then(Value::as_str) {
            Some("tool_use") => StopReason::ToolUse,
            Some("max_tokens") => StopReason::MaxTokens,
            _ => StopReason::EndTurn,
        };
        let output_tokens = value
            .pointer("/usage/output_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        vec![EventBody::Usage {
            turn: None,
            input_tokens: self.input_tokens,
            output_tokens,
            cache_read_tokens: self.cache_read,
            cache_write_tokens: self.cache_write,
            thinking_tokens: None,
            cost_usd: cost_usd(self.model.as_deref(), self.input_tokens, output_tokens),
            // The stream carries no rate limit. Section 3 gives that column
            // to claude-code alone.
            rate_limit: None,
        }]
    }
}

/// What one turn cost, from the static table.
///
/// `None` for a model the table does not know, which the schema allows and
/// which beats a wrong number on a cost display.
#[must_use]
pub fn cost_usd(model: Option<&str>, input_tokens: u64, output_tokens: u64) -> Option<f64> {
    let model = model?;
    let (_, input_price, output_price) = PRICES.iter().find(|(name, _, _)| *name == model)?;
    #[allow(clippy::cast_precision_loss)]
    let cost = (input_tokens as f64).mul_add(
        input_price / 1_000_000.0,
        (output_tokens as f64) * (output_price / 1_000_000.0),
    );
    Some(cost)
}

/// The content block index one SSE frame names.
fn index_of(value: &Value) -> u32 {
    value
        .get("index")
        .and_then(Value::as_u64)
        .and_then(|index| u32::try_from(index).ok())
        .unwrap_or(0)
}
