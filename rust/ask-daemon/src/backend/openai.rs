//! Any OpenAI-compatible server: `POST /v1/chat/completions` with SSE.
//!
//! One adapter for a family rather than for a vendor, which is why the base
//! url is configuration rather than a constant. Everything from `OpenAI`
//! itself through vLLM, llama.cpp's server and a dozen hosted gateways
//! speaks this shape.
//!
//! Section 3 calls this the barest of the four, and the code shows why.
//!
//! **Usage arrives only when asked for.** A streamed completion sends no
//! counts unless the request sets `stream_options.include_usage`, so this
//! adapter always sets it. A server that ignores the option sends no `usage`
//! chunk and the turn carries no `usage` event, which is the honest outcome.
//!
//! **`cost_usd` is always null.** The family has no shared price list and
//! the base url alone does not say who is serving, so there is nothing to
//! look a price up in.
//!
//! **Reasoning is an extension most servers do not implement.**
//! `choices[0].delta.reasoning_content` becomes a `thinking_delta` when it
//! turns up and nothing when it does not.
//!
//! The tool-call assembly is the fiddly part: fragments arrive per `index`
//! across chunks, the `id` and `name` come on the first fragment and the
//! arguments on the rest, so the map is keyed by index rather than by id.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::backend::provider::{self, ChunkDecoder, PendingToolCall, ProviderSession, TurnRequest};
use crate::backend::{
    unavailable, Backend, BackendCommand, BackendContext, BackendHandle, LineBuffer, SseDecoder,
    OPENAI,
};
use crate::proto::{BackendInfo, BackendState, ErrorKind, EventBody, StopReason};
use crate::secrets::{Secret, SecretStore};

/// The variable naming the server. There is no default: a backend that
/// guessed a base url would be a backend that talks to the wrong machine.
const BASE_URL_VAR: &str = "DOTS_ASK_OPENAI_BASE_URL";

/// The variable naming the models the pane offers, comma separated.
const MODELS_VAR: &str = "DOTS_ASK_OPENAI_MODELS";

/// The keyring attribute the API key is stored under.
pub const KEY_ATTRIBUTE: &str = "openai-api-key";

/// The SSE sentinel that ends a completion stream.
const DONE: &str = "[DONE]";

/// An OpenAI-compatible server, as the environment describes it.
pub struct OpenAiBackend {
    base_url: Option<String>,
    models: Vec<String>,
}

impl OpenAiBackend {
    /// Read the base url and the model list out of the environment.
    ///
    /// Touches no keyring, for the reason `secrets.rs` gives.
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            base_url: std::env::var(BASE_URL_VAR)
                .ok()
                .filter(|url| !url.is_empty()),
            models: std::env::var(MODELS_VAR)
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_owned)
                .collect(),
        }
    }

    /// A backend pinned to one base url.
    #[must_use]
    pub fn at(base_url: impl Into<String>) -> Self {
        Self {
            base_url: Some(base_url.into()),
            models: Vec::new(),
        }
    }
}

impl Backend for OpenAiBackend {
    fn id(&self) -> &'static str {
        OPENAI
    }

    fn info(&self, secrets: &SecretStore) -> BackendInfo {
        let Some(base_url) = &self.base_url else {
            return unavailable(
                OPENAI,
                "OpenAI-compatible",
                format!("set {BASE_URL_VAR} to the server's base url"),
            );
        };
        match secrets.cached(KEY_ATTRIBUTE) {
            Some(Secret::Found(_)) => BackendInfo {
                id: OPENAI.to_owned(),
                label: "OpenAI-compatible".to_owned(),
                state: BackendState::Ready,
                models: self.models.clone(),
                detail: Some(base_url.clone()),
            },
            Some(Secret::Missing(reason)) => unavailable(OPENAI, "OpenAI-compatible", reason),
            None => unavailable(
                OPENAI,
                "OpenAI-compatible",
                format!(
                    "{base_url}; the API key is read from the login keyring ({KEY_ATTRIBUTE}) on the first send, never at startup"
                ),
            ),
        }
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let base_url = self
            .base_url
            .clone()
            .ok_or_else(|| format!("{BASE_URL_VAR} is not set"))?;
        let model = ctx
            .model
            .clone()
            .or_else(|| self.models.first().cloned())
            .ok_or_else(|| {
                format!("this thread names no model and {MODELS_VAR} lists none to fall back to")
            })?;
        let (commands, inbox) = mpsc::unbounded_channel();
        let secrets = Arc::clone(&ctx.secrets);
        let session = ProviderSession::new(&ctx, OPENAI);
        let url = format!("{}/v1/chat/completions", base_url.trim_end_matches('/'));
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
                let Secret::Found(key) = secrets.lookup(KEY_ATTRIBUTE).await else {
                    let detail = secrets
                        .cached(KEY_ATTRIBUTE)
                        .and_then(|secret| secret.detail().map(str::to_owned))
                        .unwrap_or_else(|| "no API key in the login keyring".to_owned());
                    session.sink.fail(ErrorKind::Auth, detail, true);
                    break;
                };
                session.push_user(&blocks);
                let tools = provider::tool_schemas(&Arc::clone(&session.mcp)).await;
                let request = request(&url, &key, &model, tools);
                if !session
                    .run_turn::<OpenAiDecoder>(Some(&model), &request, &mut inbox)
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

/// The `/v1/chat/completions` request, plus how a tool result rejoins the
/// history.
fn request(url: &str, key: &str, model: &str, tools: Vec<Value>) -> TurnRequest {
    let model = model.to_owned();
    TurnRequest {
        url: url.to_owned(),
        headers: vec![("authorization".to_owned(), format!("Bearer {key}"))],
        build: Box::new(move |messages| {
            let mut body = json!({
                "model": model,
                "messages": messages,
                "stream": true,
                // Without this the stream carries no counts at all, which is
                // why section 3 says usage arrives "only when the request
                // sets stream_options.include_usage".
                "stream_options": {"include_usage": true},
            });
            if !tools.is_empty() {
                if let Some(object) = body.as_object_mut() {
                    object.insert("tools".to_owned(), Value::Array(tools.clone()));
                }
            }
            body
        }),
        record_result: Box::new(|call, _ok, content| {
            json!({
                "role": "tool",
                "tool_call_id": call.id,
                "content": content,
            })
        }),
    }
}

/// The SSE decoder for a chat-completions stream.
#[derive(Debug)]
pub struct OpenAiDecoder {
    lines: LineBuffer,
    sse: SseDecoder,
    /// Tool calls under construction, keyed by the `index` the fragments
    /// carry rather than by id, because the id only arrives on the first.
    tools: BTreeMap<u32, PendingToolCall>,
    text: String,
    stop: StopReason,
}

impl Default for OpenAiDecoder {
    fn default() -> Self {
        Self {
            lines: LineBuffer::default(),
            sse: SseDecoder::default(),
            tools: BTreeMap::new(),
            text: String::new(),
            stop: StopReason::EndTurn,
        }
    }
}

impl ChunkDecoder for OpenAiDecoder {
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
        std::mem::take(&mut self.tools).into_values().collect()
    }

    fn stop(&self) -> StopReason {
        self.stop
    }

    fn take_text(&mut self) -> String {
        std::mem::take(&mut self.text)
    }
}

impl OpenAiDecoder {
    /// Decode one SSE frame's data payload.
    fn frame(&mut self, data: &str) -> Vec<EventBody> {
        let data = data.trim();
        if data.is_empty() || data == DONE {
            return Vec::new();
        }
        let Ok(value) = serde_json::from_str::<Value>(data) else {
            return vec![provider::protocol_error(format!(
                "the completions stream sent a data frame that is not JSON: {}",
                provider::truncate(data, 200)
            ))];
        };
        if let Some(error) = value.get("error") {
            self.stop = StopReason::Error;
            return vec![provider::api_error(
                error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("the server reported an error")
                    .to_owned(),
            )];
        }

        let mut events = Vec::new();
        if let Some(delta) = value.pointer("/choices/0/delta") {
            events.extend(self.delta(delta));
        }
        if let Some(reason) = value
            .pointer("/choices/0/finish_reason")
            .and_then(Value::as_str)
        {
            self.stop = match reason {
                "tool_calls" | "function_call" => StopReason::ToolUse,
                "length" => StopReason::MaxTokens,
                "content_filter" => StopReason::Error,
                _ => StopReason::EndTurn,
            };
        }
        if let Some(usage) = value.get("usage").filter(|usage| !usage.is_null()) {
            events.push(usage_event(usage));
        }
        events
    }

    /// One `choices[0].delta`.
    fn delta(&mut self, delta: &Value) -> Vec<EventBody> {
        let mut events = Vec::new();
        if let Some(text) = delta.get("content").and_then(Value::as_str) {
            if !text.is_empty() {
                self.text.push_str(text);
                events.push(EventBody::TextDelta {
                    turn: None,
                    block: 0,
                    text: text.to_owned(),
                });
            }
        }
        if let Some(thinking) = delta.get("reasoning_content").and_then(Value::as_str) {
            if !thinking.is_empty() {
                events.push(EventBody::ThinkingDelta {
                    turn: None,
                    block: 0,
                    text: thinking.to_owned(),
                    tokens: None,
                });
            }
        }
        if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
            self.assemble(calls);
        }
        events
    }

    /// Fold tool-call fragments into the calls they belong to.
    ///
    /// Keyed by `index`, because the fragments after the first carry only
    /// the index and a slice of the arguments.
    fn assemble(&mut self, calls: &[Value]) {
        for fragment in calls {
            let index = fragment
                .get("index")
                .and_then(Value::as_u64)
                .and_then(|index| u32::try_from(index).ok())
                .unwrap_or(0);
            let call = self.tools.entry(index).or_default();
            if let Some(id) = fragment.get("id").and_then(Value::as_str) {
                id.clone_into(&mut call.id);
            }
            if let Some(name) = fragment.pointer("/function/name").and_then(Value::as_str) {
                call.name.push_str(name);
            }
            if let Some(arguments) = fragment
                .pointer("/function/arguments")
                .and_then(Value::as_str)
            {
                call.arguments.push_str(arguments);
            }
        }
    }
}

/// The `usage` event for a final chunk that carried counts.
fn usage_event(usage: &Value) -> EventBody {
    EventBody::Usage {
        turn: None,
        input_tokens: usage
            .get("prompt_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        output_tokens: usage
            .get("completion_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        // No cache split in this family, and no price: the base url alone
        // does not say who is serving, so there is nothing to price against.
        cache_read_tokens: None,
        cache_write_tokens: None,
        thinking_tokens: usage
            .pointer("/completion_tokens_details/reasoning_tokens")
            .and_then(Value::as_u64),
        cost_usd: None,
        rate_limit: None,
    }
}
