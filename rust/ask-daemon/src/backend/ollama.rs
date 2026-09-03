//! The local ollama server: `POST /api/chat`, one JSON object per line.
//!
//! The simplest of the four adapters, because ollama needs no credential and
//! streams NDJSON rather than SSE. It is also the one with the least to
//! report: section 3 of the spec says `cost_usd`, `cache_read_tokens` and
//! `cache_write_tokens` are `null` on every ollama turn, because the server
//! reports raw `prompt_eval_count` and `eval_count` and nothing else. A
//! usage panel that assumes a number is present shows zeros for a local
//! model, and that is the server's honest answer rather than a gap here.
//!
//! `message.thinking` arrives only on the handful of models that separate
//! it, which is why `thinking_delta.text` is allowed to stay empty forever.
//!
//! Tool calls arrive whole rather than streamed, in `message.tool_calls`,
//! which is the one place ollama is easier than the two SSE providers.

use std::sync::Arc;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::backend::provider::{
    self, ChunkDecoder, PendingToolCall, ProviderSession, TurnRequest,
};
use crate::backend::{Backend, BackendCommand, BackendContext, BackendHandle, LineBuffer, OLLAMA};
use crate::proto::{BackendInfo, BackendState, EventBody, StopReason};
use crate::secrets::SecretStore;

/// Where ollama listens, unless `DOTS_ASK_OLLAMA_URL` says otherwise.
pub const DEFAULT_BASE_URL: &str = "http://127.0.0.1:11434";

/// The variable that moves it.
const BASE_URL_VAR: &str = "DOTS_ASK_OLLAMA_URL";

/// The model a thread created with no model gets.
const DEFAULT_MODEL: &str = "llama3";

/// How long the startup probe waits for `/api/tags`.
///
/// Short on purpose. The probe runs before the socket is bound, and a
/// machine with no ollama must not pay for that with a slow start.
const PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

/// The local ollama server, as the startup probe found it.
pub struct OllamaBackend {
    base_url: String,
    state: BackendState,
    models: Vec<String>,
    detail: Option<String>,
}

impl OllamaBackend {
    /// Ask `/api/tags` what is installed.
    ///
    /// A refused connection is `unreachable` rather than `unconfigured`,
    /// which is the distinction the spec draws: `unconfigured` is a toggle
    /// with no credential, `unreachable` is a service that said no.
    pub async fn probed() -> Self {
        let base_url = std::env::var(BASE_URL_VAR).unwrap_or_else(|_| DEFAULT_BASE_URL.to_owned());
        let request = provider::client()
            .get(format!("{base_url}/api/tags"))
            .timeout(PROBE_TIMEOUT)
            .send()
            .await;
        match request {
            Ok(response) => match response.json::<Value>().await {
                Ok(body) => Self {
                    base_url,
                    state: BackendState::Ready,
                    models: model_names(&body),
                    detail: None,
                },
                Err(err) => Self::down(base_url, format!("/api/tags did not answer JSON: {err}")),
            },
            Err(err) => Self::down(base_url, format!("{err}")),
        }
    }

    /// A backend pinned to one base url, which is how a test points at a
    /// local fake without touching the environment.
    #[must_use]
    pub fn at(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            state: BackendState::Ready,
            models: Vec::new(),
            detail: None,
        }
    }

    /// The unreachable form, with the connect failure attached.
    fn down(base_url: String, detail: String) -> Self {
        Self {
            base_url,
            state: BackendState::Unreachable,
            models: Vec::new(),
            detail: Some(detail),
        }
    }

    /// Where this backend talks to.
    #[must_use]
    pub fn base_url(&self) -> &str {
        &self.base_url
    }
}

impl Backend for OllamaBackend {
    fn id(&self) -> &'static str {
        OLLAMA
    }

    fn info(&self, _secrets: &SecretStore) -> BackendInfo {
        BackendInfo {
            id: OLLAMA.to_owned(),
            label: "Ollama".to_owned(),
            state: self.state,
            models: self.models.clone(),
            detail: self.detail.clone(),
        }
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let (commands, inbox) = mpsc::unbounded_channel();
        let model = ctx
            .model
            .clone()
            .unwrap_or_else(|| DEFAULT_MODEL.to_owned());
        let session = ProviderSession::new(&ctx, OLLAMA);
        let url = format!("{}/api/chat", self.base_url);
        tokio::spawn(run(session, url, model, inbox));
        Ok(BackendHandle::new(commands))
    }
}

/// The model names `/api/tags` listed.
fn model_names(body: &Value) -> Vec<String> {
    body.get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|model| model.get("name").and_then(Value::as_str))
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

/// Serve one thread until its command channel closes.
async fn run(
    mut session: ProviderSession,
    url: String,
    model: String,
    mut inbox: mpsc::UnboundedReceiver<BackendCommand>,
) {
    while let Some(command) = inbox.recv().await {
        match command {
            BackendCommand::Send { blocks } => {
                session.push_user(&blocks);
                let tools = provider::tool_schemas(&Arc::clone(&session.mcp)).await;
                let request = request(&url, &model, tools);
                if !session
                    .run_turn::<OllamaDecoder>(Some(&model), &request, &mut inbox)
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

/// The `/api/chat` request, plus how a tool result rejoins the history.
fn request(url: &str, model: &str, tools: Vec<Value>) -> TurnRequest {
    let model = model.to_owned();
    TurnRequest {
        url: url.to_owned(),
        headers: Vec::new(),
        build: Box::new(move |messages| {
            let mut body = json!({
                "model": model,
                "messages": messages,
                "stream": true,
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
                "tool_name": call.name,
                "content": content,
            })
        }),
    }
}

/// The NDJSON decoder, which holds no I/O so `tests/ollama.rs` can drive it
/// straight off a recorded fixture.
#[derive(Debug)]
pub struct OllamaDecoder {
    lines: LineBuffer,
    tool_calls: Vec<PendingToolCall>,
    stop: StopReason,
    text: String,
}

impl Default for OllamaDecoder {
    fn default() -> Self {
        Self {
            lines: LineBuffer::default(),
            tool_calls: Vec::new(),
            // A stream that ends before saying why ended normally, which is
            // what a server that closed the connection cleanly means.
            stop: StopReason::EndTurn,
            text: String::new(),
        }
    }
}

impl ChunkDecoder for OllamaDecoder {
    fn push(&mut self, chunk: &str) -> Vec<EventBody> {
        let mut events = Vec::new();
        for line in self.lines.push(chunk) {
            events.extend(self.line(&line));
        }
        events
    }

    fn finish(&mut self) -> Vec<EventBody> {
        let mut events = self
            .lines
            .finish()
            .map(|line| self.line(&line))
            .unwrap_or_default();
        events.extend(provider::code_block_events(&self.text, 0));
        events
    }

    fn take_tool_calls(&mut self) -> Vec<PendingToolCall> {
        std::mem::take(&mut self.tool_calls)
    }

    fn stop(&self) -> StopReason {
        self.stop
    }

    fn take_text(&mut self) -> String {
        std::mem::take(&mut self.text)
    }
}

impl OllamaDecoder {
    /// Decode one NDJSON line.
    fn line(&mut self, line: &str) -> Vec<EventBody> {
        if line.trim().is_empty() {
            return Vec::new();
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return vec![provider::protocol_error(format!(
                "ollama wrote a line that is not JSON: {}",
                provider::truncate(line, 200)
            ))];
        };
        if let Some(error) = value.get("error").and_then(Value::as_str) {
            self.stop = StopReason::Error;
            return vec![provider::api_error(format!("ollama refused: {error}"))];
        }

        let mut events = Vec::new();
        if let Some(text) = value.pointer("/message/content").and_then(Value::as_str) {
            if !text.is_empty() {
                self.text.push_str(text);
                events.push(EventBody::TextDelta {
                    turn: None,
                    block: 0,
                    text: text.to_owned(),
                });
            }
        }
        if let Some(thinking) = value.pointer("/message/thinking").and_then(Value::as_str) {
            if !thinking.is_empty() {
                events.push(EventBody::ThinkingDelta {
                    turn: None,
                    block: 0,
                    text: thinking.to_owned(),
                    tokens: None,
                });
            }
        }
        if let Some(calls) = value.pointer("/message/tool_calls").and_then(Value::as_array) {
            self.collect_tool_calls(calls);
        }
        if value.get("done").and_then(Value::as_bool) == Some(true) {
            events.push(self.done(&value));
        }
        events
    }

    /// Tool calls arrive whole rather than streamed, so there is nothing to
    /// assemble across chunks. ollama sends no call id either, so one is
    /// synthesized from the position.
    fn collect_tool_calls(&mut self, calls: &[Value]) {
        for call in calls {
            let Some(function) = call.get("function") else {
                continue;
            };
            let index = self.tool_calls.len();
            self.tool_calls.push(PendingToolCall {
                id: format!("ollama-{index}"),
                name: function
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                arguments: function
                    .get("arguments")
                    .map_or_else(String::new, ToString::to_string),
            });
        }
    }

    /// The final chunk, which is the only one that carries counts.
    fn done(&mut self, value: &Value) -> EventBody {
        self.stop = match value.get("done_reason").and_then(Value::as_str) {
            Some("length") => StopReason::MaxTokens,
            _ if !self.tool_calls.is_empty() => StopReason::ToolUse,
            _ => StopReason::EndTurn,
        };
        EventBody::Usage {
            turn: None,
            input_tokens: value
                .get("prompt_eval_count")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            output_tokens: value.get("eval_count").and_then(Value::as_u64).unwrap_or(0),
            // No cache split and no price. Section 3 states this outright:
            // ollama reports these two counts and nothing else.
            cache_read_tokens: None,
            cache_write_tokens: None,
            thinking_tokens: None,
            cost_usd: None,
            rate_limit: None,
        }
    }
}
