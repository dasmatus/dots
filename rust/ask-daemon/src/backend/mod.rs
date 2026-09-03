//! The `Backend` trait, the registry, and the pieces every adapter shares.
//!
//! One trait covers both kinds of backend. A harness backend spawns a child
//! process and parses its stdout; a provider backend opens an HTTP stream.
//! Both emit the same normalized events into the same channel and take the
//! same three commands, so `server.rs` never branches on which kind it has.
//!
//! ## Why the trait is synchronous
//!
//! [`Backend::start`] is a plain `fn`, and that is not an oversight.
//!
//! `Hub::dispatch` holds a `std::sync::Mutex` for a whole frame, and every
//! persisted enqueue happens inside it. That is what makes replay exact: the
//! order a client reads is the order the store holds. A guard held across an
//! await makes the future non-`Send`, so the compiler enforces it, and
//! anything the dispatch path calls has to be callable without awaiting.
//!
//! Starting a backend is callable without awaiting. `tokio::process::Command
//! ::spawn` returns as soon as the fork succeeds, and a provider backend's
//! start is a `tokio::spawn` and nothing else. Everything that genuinely
//! blocks, meaning the keyring lookup, the HTTP connect and every byte of
//! the stream, happens inside the task [`Backend::start`] leaves behind.
//!
//! Traffic in the other direction follows the same rule. A [`BackendHandle`]
//! carries an unbounded `mpsc::UnboundedSender`, whose `send` is
//! non-blocking and synchronous, so `dispatch` can hand a command to a
//! running backend from inside the critical section without ever awaiting.
//!
//! ## Turn ids
//!
//! An adapter emits an [`EventBody`] with `turn: None` and
//! `Session::adopt` fills it in. A backend cannot know the turn id: it is
//! minted in `session.rs` and never leaves the daemon. Doing it in one place
//! also means an adapter cannot open a second turn over a running one.

pub mod anthropic;
pub mod claude_code;
pub mod codex;
pub mod ollama;
pub mod openai;
pub mod provider;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde_json::Value;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::mcp::McpPool;
use crate::policy::Policy;
use crate::proto::{
    BackendInfo, BackendState, ErrorKind, EventBody, PermissionDecision, PermissionScope, SendBlock,
};
use crate::secrets::SecretStore;

/// The id `claude-code` is registered under, and the daemon's default.
pub const CLAUDE_CODE: &str = "claude-code";

/// The id the Anthropic Messages API backend is registered under.
pub const ANTHROPIC: &str = "anthropic";

/// The id the OpenAI-compatible backend is registered under.
pub const OPENAI: &str = "openai-compatible";

/// The id the local ollama backend is registered under.
pub const OLLAMA: &str = "ollama";

/// The id the codex stub is registered under.
pub const CODEX: &str = "codex";

/// One command the daemon hands a running backend.
///
/// Every variant is something a client frame produced, which is why there is
/// no variant for anything the daemon decides on its own.
#[derive(Debug, Clone)]
pub enum BackendCommand {
    /// A user message to answer.
    Send {
        /// The message body, in order.
        blocks: Vec<SendBlock>,
    },
    /// Stop the running turn. The turn ends with `stop: "interrupted"` and
    /// no `error`, because the client asked for this.
    Interrupt,
    /// A decision on an open permission request.
    Permission {
        /// The backend's own request id.
        request: String,
        /// Allow or deny.
        decision: PermissionDecision,
        /// How long the decision lasts. The harness ignores it, because the
        /// CLI resolves one call at a time and has no rule store this daemon
        /// writes to. A provider backend hands it to `policy.rs`, which is
        /// where `forever` becomes a line in `policy.json`.
        scope: PermissionScope,
        /// Replacement tool arguments when the user edited them.
        updated_input: Option<Value>,
        /// The reason text sent back on a denial.
        message: Option<String>,
    },
    /// Close the backend down. Sent when the thread is deleted.
    Shutdown,
}

/// One normalized event, addressed to the conversation that produced it.
///
/// The pump reads these off one channel shared by every running backend, so
/// the conversation travels with the body rather than with the channel.
#[derive(Debug)]
pub struct BackendMessage {
    /// The thread the event belongs to.
    pub conversation: Uuid,
    /// The event, with `turn: None` for `Session::adopt` to fill in.
    pub body: EventBody,
}

/// Where a backend sends what it produced.
///
/// Cloned into each backend task. Sending is synchronous and non-blocking,
/// so a backend never blocks on a slow pump, and the pump is the only thing
/// that takes the hub lock.
#[derive(Clone)]
pub struct EventSink {
    conversation: Uuid,
    events: mpsc::UnboundedSender<BackendMessage>,
}

impl EventSink {
    /// A sink for one conversation over a shared channel.
    #[must_use]
    pub fn new(conversation: Uuid, events: mpsc::UnboundedSender<BackendMessage>) -> Self {
        Self {
            conversation,
            events,
        }
    }

    /// The thread this sink belongs to.
    #[must_use]
    pub fn conversation(&self) -> Uuid {
        self.conversation
    }

    /// Queue one event, reporting whether the daemon is still listening.
    ///
    /// False means the pump is gone, which happens only at shutdown, and the
    /// caller uses it to stop reading its transport rather than to raise an
    /// error nobody would see.
    pub fn emit(&self, body: EventBody) -> bool {
        self.events
            .send(BackendMessage {
                conversation: self.conversation,
                body,
            })
            .is_ok()
    }

    /// Queue a conversation-scoped `error`.
    ///
    /// `fatal` true means the thread is dead and the pane should offer a new
    /// one, which is what a spawn failure and a refused credential both are.
    pub fn fail(&self, kind: ErrorKind, message: String, fatal: bool) -> bool {
        tracing::warn!(conversation = %self.conversation, ?kind, message, "backend failure");
        self.emit(EventBody::Error {
            kind,
            message,
            fatal,
        })
    }
}

/// Everything a backend needs to run one thread.
pub struct BackendContext {
    /// The thread this backend serves.
    pub conversation: Uuid,
    /// The model the thread was created with, `None` for the backend's own
    /// default.
    pub model: Option<String>,
    /// The working directory the thread is scoped to.
    pub cwd: PathBuf,
    /// Where to send normalized events.
    pub sink: EventSink,
    /// The lazy keyring reader. Nothing here touches it until a turn needs a
    /// credential.
    pub secrets: Arc<SecretStore>,
    /// The MCP servers a provider backend may call tools on. Empty for the
    /// harness, which runs its own tools.
    pub mcp: Arc<McpPool>,
    /// The approval store, shared with the hub so a `forever` rule written
    /// by one thread is the rule the next one reads.
    ///
    /// A `std::sync::Mutex` rather than tokio's, because every use of it is
    /// a map lookup or a small file write with no await inside, and the
    /// blocking form is the one `Hub::dispatch` can also take.
    pub policy: Arc<Mutex<Policy>>,
}

/// A running backend, addressed by the commands it accepts.
///
/// Dropping the handle closes the command channel, which every adapter reads
/// as a shutdown, so a thread that goes away takes its backend with it.
#[derive(Debug)]
pub struct BackendHandle {
    commands: mpsc::UnboundedSender<BackendCommand>,
}

impl BackendHandle {
    /// Wrap the sending half of a backend's command channel.
    #[must_use]
    pub fn new(commands: mpsc::UnboundedSender<BackendCommand>) -> Self {
        Self { commands }
    }

    /// Hand the backend one command.
    ///
    /// Synchronous and non-blocking, which is what lets `Hub::dispatch` call
    /// it from inside the lock. False means the backend task has ended and
    /// the caller should drop the handle.
    pub fn send(&self, command: BackendCommand) -> bool {
        self.commands.send(command).is_ok()
    }
}

/// One backend the daemon can run.
///
/// Implementors are stateless descriptions. All the state lives in the task
/// [`Backend::start`] leaves behind, which is why one `Arc<dyn Backend>` in
/// the registry serves every conversation at once.
pub trait Backend: Send + Sync {
    /// The id an `op:"new"` names, and the id `turn_start.backend` carries.
    fn id(&self) -> &'static str;

    /// What the pane shows in its backend list.
    ///
    /// This must not block and must not touch the keyring. A backend whose
    /// availability is only knowable by reading a credential reports
    /// `unconfigured` with a detail line saying so, and upgrades itself once
    /// a turn has actually caused the lookup.
    fn info(&self, secrets: &SecretStore) -> BackendInfo;

    /// Whether this backend can produce `diff` and `plan` events.
    ///
    /// False for every raw provider: both come from harness tools, and in
    /// provider mode there are no file tools at all. The pane hides the diff
    /// view and the plan card rather than waiting for data that never comes.
    fn produces_diffs_and_plans(&self) -> bool {
        false
    }

    /// Start the backend for one thread.
    ///
    /// This must return without awaiting, because the caller holds the hub
    /// lock. Everything slow belongs in the spawned task.
    ///
    /// # Errors
    ///
    /// Whatever stopped the backend from starting at all, which the caller
    /// turns into a conversation-scoped `error` with
    /// [`ErrorKind::BackendSpawn`]. A failure the task discovers later
    /// arrives as an event on the sink instead, because by then a thread
    /// exists to file it against.
    fn start(&self, ctx: BackendContext) -> Result<BackendHandle, String>;
}

/// The backends this build offers, in display order.
pub struct Registry {
    backends: Vec<Arc<dyn Backend>>,
    secrets: Arc<SecretStore>,
    mcp: Arc<McpPool>,
    policy: Arc<Mutex<Policy>>,
}

impl Registry {
    /// Build the registry from a backend list.
    #[must_use]
    pub fn new(
        backends: Vec<Arc<dyn Backend>>,
        secrets: Arc<SecretStore>,
        mcp: Arc<McpPool>,
        policy: Arc<Mutex<Policy>>,
    ) -> Self {
        Self {
            backends,
            secrets,
            mcp,
            policy,
        }
    }

    /// The approval store this registry hands every backend it starts.
    #[must_use]
    pub fn policy(&self) -> Arc<Mutex<Policy>> {
        Arc::clone(&self.policy)
    }

    /// Drop the `session` approvals a deleted thread carried.
    ///
    /// `forever` rules stay: a person who removed a conversation removed a
    /// transcript, not a decision they made about which tools may run.
    pub fn forget_session(&self, conversation: Uuid) {
        match self.policy.lock() {
            Ok(mut policy) => policy.forget_session(conversation),
            Err(poisoned) => poisoned.into_inner().forget_session(conversation),
        }
    }

    /// Every backend the spec names, probed as far as probing is free.
    ///
    /// Free means no keyring. `claude-code` is decided by whether `claude`
    /// resolves on `PATH`, `ollama` by whether 11434 answers, and the two
    /// keyed providers report `unconfigured` until a turn causes the lookup.
    /// That asymmetry is the laziness rule in `secrets.rs` showing through,
    /// and it is deliberate: a probe that can hang for ten seconds must not
    /// run before the socket exists.
    pub async fn discover(
        secrets: Arc<SecretStore>,
        mcp: Arc<McpPool>,
        policy: Arc<Mutex<Policy>>,
    ) -> Self {
        let ollama = ollama::OllamaBackend::probed().await;
        let backends: Vec<Arc<dyn Backend>> = vec![
            Arc::new(claude_code::ClaudeCodeBackend::detected()),
            Arc::new(anthropic::AnthropicBackend::from_env()),
            Arc::new(openai::OpenAiBackend::from_env()),
            Arc::new(ollama),
            Arc::new(codex::CodexBackend),
        ];
        Self::new(backends, secrets, mcp, policy)
    }

    /// The `backends` event's payload.
    #[must_use]
    pub fn info(&self) -> Vec<BackendInfo> {
        self.backends
            .iter()
            .map(|backend| backend.info(&self.secrets))
            .collect()
    }

    /// Whether `id` names a backend this daemon has.
    #[must_use]
    pub fn contains(&self, id: &str) -> bool {
        self.backends.iter().any(|backend| backend.id() == id)
    }

    /// Start one thread's backend.
    ///
    /// # Errors
    ///
    /// A message naming what stopped it, which the caller raises as a
    /// conversation-scoped `error` with [`ErrorKind::BackendSpawn`].
    pub fn start(
        &self,
        id: &str,
        conversation: Uuid,
        model: Option<String>,
        cwd: &Path,
        events: mpsc::UnboundedSender<BackendMessage>,
    ) -> Result<BackendHandle, String> {
        let backend = self
            .backends
            .iter()
            .find(|backend| backend.id() == id)
            .ok_or_else(|| format!("no backend {id:?} is registered"))?;
        backend.start(BackendContext {
            conversation,
            model,
            cwd: cwd.to_path_buf(),
            sink: EventSink::new(conversation, events),
            secrets: Arc::clone(&self.secrets),
            mcp: Arc::clone(&self.mcp),
            policy: Arc::clone(&self.policy),
        })
    }
}

/// A registry that lists every backend the spec names and starts none of
/// them.
///
/// This is what a build with nothing configured looks like, and it is what
/// `tests/server.rs` drives the socket against: the ids are real, so
/// `op:"new"` still validates against them, and every `send` raises a
/// conversation-scoped `backend_spawn`. Using it in a test also means the
/// suite can never reach out to a real `claude` on `PATH` or a real ollama
/// on 11434.
#[must_use]
pub fn unconfigured_registry() -> Arc<Registry> {
    let detail = "no backend is configured in this build";
    let backends: Vec<Arc<dyn Backend>> = [
        (CLAUDE_CODE, "Claude Code"),
        (ANTHROPIC, "Anthropic API"),
        (OPENAI, "OpenAI-compatible"),
        (OLLAMA, "Ollama"),
        (CODEX, "Codex"),
    ]
    .into_iter()
    .map(|(id, label)| -> Arc<dyn Backend> {
        Arc::new(Unconfigured {
            id,
            label,
            detail: detail.to_owned(),
        })
    })
    .collect();
    let policy = Policy::open(PathBuf::from("/nonexistent/dots-ask/policy.json"))
        .unwrap_or_else(|_| unreachable!("a policy file that is not there loads as empty"));
    Arc::new(Registry::new(
        backends,
        Arc::new(SecretStore::default()),
        Arc::new(McpPool::empty()),
        Arc::new(Mutex::new(policy)),
    ))
}

/// A backend that exists in the list and does nothing else.
struct Unconfigured {
    id: &'static str,
    label: &'static str,
    detail: String,
}

impl Backend for Unconfigured {
    fn id(&self) -> &'static str {
        self.id
    }

    fn info(&self, _secrets: &SecretStore) -> BackendInfo {
        unavailable(self.id, self.label, self.detail.clone())
    }

    fn start(&self, _ctx: BackendContext) -> Result<BackendHandle, String> {
        Err(format!("backend {:?} is not configured", self.id))
    }
}

/// A backend that is present but not usable, with the reason attached.
#[must_use]
pub fn unavailable(id: &'static str, label: &str, detail: String) -> BackendInfo {
    BackendInfo {
        id: id.to_owned(),
        label: label.to_owned(),
        state: BackendState::Unconfigured,
        models: Vec::new(),
        detail: Some(detail),
    }
}

/// Whether a program resolves on `PATH`.
///
/// Used by the harness backend, which is available exactly when its CLI is.
/// `which` is not shelled out to: `PATH` is a list of directories and an
/// executable bit, and a subprocess to read them would be one more thing to
/// go wrong at startup.
#[must_use]
pub fn on_path(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| is_executable(candidate))
}

/// Whether one path is a file this user can execute.
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Split a byte stream into complete lines, keeping the incomplete tail.
///
/// Every provider transport in this module is line-oriented: NDJSON is one
/// object per line, and an SSE frame is a run of `field: value` lines ended
/// by a blank one. A chunk off the wire respects neither boundary, so this
/// buffers the remainder rather than losing it or parsing half of it.
#[derive(Debug, Default)]
pub struct LineBuffer {
    pending: String,
}

impl LineBuffer {
    /// Feed one chunk, returning the complete lines it finished.
    ///
    /// Lines come back with their terminator stripped, and a trailing `\r`
    /// goes with it, because SSE is specified with CRLF and every server
    /// disagrees about whether to send it.
    pub fn push(&mut self, chunk: &str) -> Vec<String> {
        self.pending.push_str(chunk);
        let mut lines = Vec::new();
        while let Some(end) = self.pending.find('\n') {
            let mut line = self.pending.drain(..=end).collect::<String>();
            line.truncate(line.trim_end_matches(['\n', '\r']).len());
            lines.push(line);
        }
        lines
    }

    /// Whatever is left when the stream ends, if it is not empty.
    ///
    /// A server that ends without a final newline still sent a whole
    /// message, and dropping it would lose the last chunk of a turn.
    pub fn finish(&mut self) -> Option<String> {
        let tail = std::mem::take(&mut self.pending);
        let trimmed = tail.trim_end_matches(['\n', '\r']);
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    }
}

/// One decoded server-sent event.
///
/// Only the two fields the Anthropic and `OpenAI` streams use are kept. `id`
/// and `retry` exist in the SSE specification and neither provider sends
/// anything the daemon would do with them.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SseFrame {
    /// The `event:` field, empty when the server sent none.
    pub name: String,
    /// The `data:` field, with multiple `data:` lines joined by newlines as
    /// the SSE specification requires.
    pub data: String,
}

/// Assembles SSE frames out of lines.
///
/// Both provider backends that speak SSE share this, because the framing is
/// the same standard on both and only the payload differs.
#[derive(Debug, Default)]
pub struct SseDecoder {
    current: SseFrame,
}

impl SseDecoder {
    /// Feed one line, returning a frame when the line closed one.
    ///
    /// A blank line ends a frame. A line starting with `:` is a comment,
    /// which is what a keepalive is, and produces nothing.
    pub fn push(&mut self, line: &str) -> Option<SseFrame> {
        if line.is_empty() {
            let frame = std::mem::take(&mut self.current);
            return (!frame.data.is_empty() || !frame.name.is_empty()).then_some(frame);
        }
        if line.starts_with(':') {
            return None;
        }
        let (field, value) = match line.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            None => (line, ""),
        };
        match field {
            "event" => value.clone_into(&mut self.current.name),
            "data" => {
                if !self.current.data.is_empty() {
                    self.current.data.push('\n');
                }
                self.current.data.push_str(value);
            }
            _ => {}
        }
        None
    }
}
