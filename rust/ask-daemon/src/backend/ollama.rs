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

use crate::backend::provider::{self, ChunkDecoder, PendingToolCall, ProviderSession, TurnRequest};
use crate::backend::{Backend, BackendCommand, BackendContext, BackendHandle, LineBuffer, OLLAMA};
use crate::proto::{BackendInfo, BackendState, EventBody, StopReason};
use crate::secrets::SecretStore;

/// Where ollama listens, unless `DOTS_ASK_OLLAMA_URL` says otherwise.
pub const DEFAULT_BASE_URL: &str = "http://127.0.0.1:11434";

/// The variable that moves it.
const BASE_URL_VAR: &str = "DOTS_ASK_OLLAMA_URL";

/// Where the daemon reads how much memory is going spare.
///
/// `MemAvailable` rather than `MemFree`, because the kernel's own estimate
/// of what a new allocation could have is the number that matters; `MemFree`
/// on a box with a warm page cache reads near zero and would pick the
/// smallest model every time.
const MEMINFO: &str = "/proc/meminfo";

/// How much of available memory one model may claim.
///
/// A model that exactly fills the space leaves nothing for the context
/// window, the KV cache or the rest of the desktop, and ollama then either
/// swaps or falls back to CPU. Two thirds is a guess, but it is a guess in
/// the safe direction and it is written down rather than buried.
const MEMORY_HEADROOM: f64 = 0.66;

/// How long the startup probe waits for `/api/tags`.
///
/// Short on purpose. The probe runs before the socket is bound, and a
/// machine with no ollama must not pay for that with a slow start.
const PROBE_TIMEOUT: Duration = Duration::from_millis(1500);

/// One model `/api/tags` reported as installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledModel {
    /// The tag, which is what `/api/chat` takes as `model`.
    pub name: String,
    /// How much disk the blobs take, which is the closest thing `/api/tags`
    /// gives to how much memory loading it will want.
    pub size_bytes: u64,
}

/// The local ollama server, as the startup probe found it.
pub struct OllamaBackend {
    base_url: String,
    state: BackendState,
    models: Vec<InstalledModel>,
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
                    models: installed_models(&body),
                    detail: None,
                },
                Err(err) => Self::down(base_url, format!("/api/tags did not answer JSON: {err}")),
            },
            Err(err) => Self::down(base_url, format!("{err}")),
        }
    }

    /// A backend pinned to one base url and one model list, which is how a
    /// test points at a local fake without touching the environment.
    #[must_use]
    pub fn at(base_url: impl Into<String>, models: Vec<InstalledModel>) -> Self {
        Self {
            base_url: base_url.into(),
            state: BackendState::Ready,
            models,
            detail: None,
        }
    }

    /// The models this server has, as the probe found them.
    #[must_use]
    pub fn models(&self) -> &[InstalledModel] {
        &self.models
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
            models: self.models.iter().map(|model| model.name.clone()).collect(),
            detail: self.detail.clone(),
        }
    }

    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String> {
        let model = match ctx.model.clone() {
            Some(model) => model,
            None => choose_model(&self.models, available_memory())
                .ok_or_else(|| {
                    "ollama has no model installed; pull one with `ollama pull`".to_owned()
                })?
                .to_owned(),
        };
        let (commands, inbox) = mpsc::unbounded_channel();
        let session = ProviderSession::new(&ctx, OLLAMA);
        let url = format!("{}/api/chat", self.base_url);
        tokio::spawn(run(session, url, model, inbox));
        Ok(BackendHandle::new(commands))
    }
}

/// The models `/api/tags` listed, with their sizes.
fn installed_models(body: &Value) -> Vec<InstalledModel> {
    body.get("models")
        .and_then(Value::as_array)
        .map(|models| {
            models
                .iter()
                .filter_map(|model| {
                    Some(InstalledModel {
                        name: model.get("name").and_then(Value::as_str)?.to_owned(),
                        size_bytes: model.get("size").and_then(Value::as_u64).unwrap_or(0),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Pick the model a thread that names none should run.
///
/// No tag is written into this file. A tag hardcoded in Rust is stale the
/// day the next model ships, and it names something this machine may never
/// have pulled, so the daemon would answer a `send` with a 404 from a server
/// that is running perfectly well. The list comes from `/api/tags` instead.
///
/// Among what is installed, the biggest model that fits is the best one: a
/// larger local model is a better answer, and the only thing stopping it is
/// memory. "Fits" is [`MEMORY_HEADROOM`] of what the kernel says is
/// available, because the weights are not the only thing that has to be
/// resident. When nothing fits, the smallest installed model is still a
/// better answer than refusing, since ollama will page or fall back to CPU
/// and be slow rather than fail.
///
/// `available` is a parameter rather than read here, so this is a pure
/// function a test can drive.
#[must_use]
pub fn choose_model(models: &[InstalledModel], available: Option<u64>) -> Option<&str> {
    let budget = available.map(|bytes| {
        #[allow(clippy::cast_precision_loss, clippy::cast_sign_loss)]
        let budget = (bytes as f64 * MEMORY_HEADROOM) as u64;
        budget
    });
    let fitting = budget.and_then(|budget| {
        models
            .iter()
            .filter(|model| model.size_bytes <= budget)
            .max_by_key(|model| (model.size_bytes, &model.name))
    });
    fitting
        .or_else(|| {
            models
                .iter()
                .min_by_key(|model| (model.size_bytes, &model.name))
        })
        .map(|model| model.name.as_str())
}

/// How much memory the kernel says a new allocation could have.
///
/// `None` when `/proc/meminfo` is not readable, which is what a sandbox with
/// no `/proc` looks like. The caller then falls back to the smallest model,
/// which is the right answer when the daemon cannot tell how much room it
/// has.
#[must_use]
pub fn available_memory() -> Option<u64> {
    let meminfo = std::fs::read_to_string(MEMINFO).ok()?;
    meminfo
        .lines()
        .find_map(|line| line.strip_prefix("MemAvailable:"))
        .and_then(|value| value.split_whitespace().next())
        .and_then(|kilobytes| kilobytes.parse::<u64>().ok())
        .map(|kilobytes| kilobytes.saturating_mul(1024))
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
///
/// Public so `tests/provider.rs` can drive the real turn loop against a fake
/// server rather than a re-implementation of this shape.
pub fn request(url: &str, model: &str, tools: Vec<Value>) -> TurnRequest {
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
        // ollama takes the arguments back as an object, the same way it sent
        // them, rather than as the JSON text the two OpenAI-shaped families
        // use.
        record_assistant: Box::new(|text, calls| {
            if text.is_empty() && calls.is_empty() {
                return None;
            }
            let mut message = json!({"role": "assistant", "content": text});
            if !calls.is_empty() {
                if let Some(object) = message.as_object_mut() {
                    object.insert(
                        "tool_calls".to_owned(),
                        calls
                            .iter()
                            .map(|call| {
                                json!({"function": {
                                    "name": call.name,
                                    "arguments": call.input(),
                                }})
                            })
                            .collect(),
                    );
                }
            }
            Some(message)
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
        if let Some(calls) = value
            .pointer("/message/tool_calls")
            .and_then(Value::as_array)
        {
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
