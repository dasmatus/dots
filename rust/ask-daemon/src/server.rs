//! The unix listener, one newline-delimited JSON loop per client, resume
//! replay, and fan-out to every connected client.
//!
//! More than one client can be attached, and all of them see the same
//! conversation events. Getting that right without holes is the whole job of
//! this module, and it rests on three things.
//!
//! One lock covers allocating a `seq`, appending it to the store, and
//! publishing it to the fan-out. So the order clients see is the order the
//! store holds, and no event can be published before it is durable.
//!
//! A connection subscribes to the fan-out inside that same lock, in the same
//! critical section that reads its replay. An event is therefore in the
//! replay or in the subscription, never in both and never in neither. That is
//! what makes a reconnect with `resume_seq` deliver exactly the missed
//! events.
//!
//! The pump that drains the fan-out remembers the highest `seq` it has
//! written. A client too slow to keep up gets a `Lagged` from the broadcast
//! channel, and rather than leaving a hole the pump refills from the store
//! and carries on. The same counter makes a duplicate impossible, because
//! anything at or below it is dropped.
//!
//! `open` is deliberately outside all of that. It answers one connection with
//! the events it asks for and does not touch the pump's counter, because the
//! client is the one that knows what it already holds.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};
use uuid::Uuid;

use crate::proto::{
    decode_client_line, encode_server_line, BackendInfo, BackendState, ClientFrame,
    ConversationMeta, ErrorKind, EventBody, ServerEvent, PROTOCOL_VERSION,
};
use crate::session::Session;
use crate::store::Store;
use crate::AskError;

/// The socket's name under `$XDG_RUNTIME_DIR`.
const SOCKET_NAME: &str = "dots-ask.sock";

/// The state root's name under `$XDG_DATA_HOME`.
const STATE_DIR_NAME: &str = "dots-ask";

/// How many events the fan-out holds for a client that is behind.
///
/// Overflowing is not a loss: the pump refills from the store. The number
/// only decides how often a slow client pays for a re-read.
const FANOUT_DEPTH: usize = 4096;

/// How many events one connection's outbox holds before the producer waits.
const OUTBOX_DEPTH: usize = 4096;

/// How long the accept loop pauses after a failed accept, so a persistent
/// failure such as running out of descriptors cannot spin a core.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(200);

/// Unix milliseconds now.
///
/// Clamped rather than failing, because a clock before the epoch is not a
/// reason to drop a turn on the floor.
#[must_use]
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| {
            u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
        })
}

/// The socket path, `$XDG_RUNTIME_DIR/dots-ask.sock`.
///
/// # Errors
///
/// [`AskError::NoRuntimeDir`] when the variable is unset, because a socket in
/// a guessed directory would be a socket nothing can find.
pub fn default_socket_path() -> Result<PathBuf, AskError> {
    std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|dir| !dir.is_empty())
        .map(|dir| PathBuf::from(dir).join(SOCKET_NAME))
        .ok_or(AskError::NoRuntimeDir)
}

/// The state root, `$XDG_DATA_HOME/dots-ask`, falling back to
/// `~/.local/share/dots-ask`.
///
/// # Errors
///
/// [`AskError::NoDataHome`] when neither variable is set.
pub fn default_state_root() -> Result<PathBuf, AskError> {
    if let Some(data_home) = std::env::var_os("XDG_DATA_HOME").filter(|dir| !dir.is_empty()) {
        return Ok(PathBuf::from(data_home).join(STATE_DIR_NAME));
    }
    std::env::var_os("HOME")
        .filter(|dir| !dir.is_empty())
        .map(|home| {
            PathBuf::from(home)
                .join(".local")
                .join("share")
                .join(STATE_DIR_NAME)
        })
        .ok_or(AskError::NoDataHome)
}

/// The backends this build can offer.
///
/// Every id the spec names is listed as `unconfigured`, which is the truthful
/// state: this phase ships no backend at all. Phase 2 replaces this with
/// `src/backend/mod.rs`, which reads the `dots.ai.*` toggles and probes each
/// one. The list still does real work today, because `op:"new"` validates its
/// `backend` against it and a `send` reports this `detail` back.
#[must_use]
pub fn placeholder_backends() -> Vec<BackendInfo> {
    let unwired = "no backend runs until the ask pane's backend phase lands";
    [
        ("claude-code", "Claude Code"),
        ("anthropic", "Anthropic API"),
        ("openai-compatible", "OpenAI-compatible"),
        ("ollama", "Ollama"),
        ("codex", "Codex"),
    ]
    .into_iter()
    .map(|(id, label)| BackendInfo {
        id: id.to_owned(),
        label: label.to_owned(),
        state: BackendState::Unconfigured,
        models: Vec::new(),
        detail: Some(unwired.to_owned()),
    })
    .collect()
}

/// The shared state every connection works against.
pub struct Hub {
    inner: Mutex<HubInner>,
    fanout: broadcast::Sender<Arc<ServerEvent>>,
    backends: Vec<BackendInfo>,
}

/// Everything the lock covers.
struct HubInner {
    store: Store,
    sessions: BTreeMap<Uuid, Session>,
}

impl Hub {
    /// Open the store at `state_root` and build the hub around it.
    ///
    /// Any turn a previous run left open is closed here, before the listener
    /// exists, so no client can attach in the middle of recovery.
    ///
    /// # Errors
    ///
    /// Whatever [`Store::open`] returns.
    pub fn open(state_root: PathBuf, backends: Vec<BackendInfo>) -> Result<Arc<Self>, AskError> {
        let loaded = Store::open(state_root, now_ms())?;
        if !loaded.recovered.is_empty() {
            tracing::info!(
                turns = loaded.recovered.len(),
                "closed turns that a previous run left open"
            );
        }
        let (fanout, _) = broadcast::channel(FANOUT_DEPTH);
        Ok(Arc::new(Self {
            inner: Mutex::new(HubInner {
                store: loaded.store,
                sessions: loaded.sessions,
            }),
            fanout,
            backends,
        }))
    }

    /// Take the lock, recovering from a poisoned one.
    ///
    /// A panic in one connection's critical section must not take the daemon
    /// down with it: the store's own invariants are re-read from disk, and
    /// the worst a poisoned lock can leave behind is a half-updated index
    /// entry, which the next write corrects.
    fn lock(&self) -> MutexGuard<'_, HubInner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Persist a conversation event and publish it to every attached client.
    ///
    /// Both happen under one lock, so the order on the wire is the order in
    /// the store.
    fn emit(
        inner: &mut HubInner,
        fanout: &broadcast::Sender<Arc<ServerEvent>>,
        conversation: Uuid,
        body: EventBody,
        now: u64,
    ) -> Result<(), AskError> {
        if let Some(session) = inner.sessions.get_mut(&conversation) {
            session.apply(&body);
        }
        let event = inner.store.record(conversation, body, now)?;
        // A send with no receivers is not a failure: no client has said
        // hello yet, and the event is already durable for the one that will.
        drop(fanout.send(Arc::new(event)));
        Ok(())
    }

    /// Handle one decoded client frame.
    ///
    /// This never fails. A store failure becomes a connection-scoped `error`
    /// with kind `store`, because the thing that would have recorded the
    /// failure is the thing that just failed.
    fn dispatch(&self, frame: ClientFrame) -> Reply {
        let now = now_ms();
        let mut inner = self.lock();
        match frame {
            ClientFrame::Hello {
                protocol,
                resume_seq,
            } => self.hello(&inner, protocol, resume_seq),
            ClientFrame::List { limit, before } => Reply::direct(EventBody::Conversations {
                items: inner.store.list(limit, before),
            }),
            ClientFrame::Open {
                conversation,
                from_seq,
            } => {
                if !inner.store.contains(conversation) {
                    return Reply::bad_request(format!("unknown conversation {conversation}"));
                }
                match inner
                    .store
                    .conversation_events_after(conversation, from_seq)
                {
                    Ok(events) => Reply::Direct(events),
                    Err(err) => Reply::store_failure(&err),
                }
            }
            ClientFrame::New {
                conversation,
                backend,
                model,
                cwd,
                title,
            } => self.new_thread(
                &mut inner,
                ConversationMeta {
                    id: conversation,
                    title,
                    backend,
                    model,
                    cwd,
                    updated_ms: now,
                    turns: 0,
                },
            ),
            ClientFrame::Send {
                conversation,
                blocks,
            } => {
                if !inner.store.contains(conversation) {
                    return Reply::bad_request(format!("unknown conversation {conversation}"));
                }
                if blocks.is_empty() {
                    return Reply::bad_request("send carries no blocks".to_owned());
                }
                for block in &blocks {
                    if let Err(message) = block.validate() {
                        return Reply::bad_request(message);
                    }
                }
                self.spawn_backend(&mut inner, conversation, now)
            }
            ClientFrame::Interrupt { conversation } => {
                let Some(session) = inner.sessions.get_mut(&conversation) else {
                    return Reply::bad_request(format!("unknown conversation {conversation}"));
                };
                // Nothing running is not an error. The pane can fire this at
                // a thread that just finished, and the user's intent is
                // already satisfied.
                let Some(body) = session.interrupt(now) else {
                    return Reply::Direct(Vec::new());
                };
                match Self::emit(&mut inner, &self.fanout, conversation, body, now) {
                    Ok(()) => Reply::Direct(Vec::new()),
                    Err(err) => Reply::store_failure(&err),
                }
            }
            ClientFrame::Permission {
                conversation,
                request,
                ..
            } => {
                let Some(session) = inner.sessions.get_mut(&conversation) else {
                    return Reply::bad_request(format!("unknown conversation {conversation}"));
                };
                // An id nothing is waiting on is an argument the daemon
                // cannot resolve, which the scope table calls bad_request.
                if session.resolve_permission(&request).is_none() {
                    return Reply::bad_request(format!(
                        "no permission request {request:?} is open on {conversation}"
                    ));
                }
                // The decision has nowhere to go until a backend is running,
                // so the backend phase hooks its control_response in here.
                Reply::Direct(Vec::new())
            }
            ClientFrame::Delete { conversation } => {
                if !inner.store.contains(conversation) {
                    return Reply::bad_request(format!("unknown conversation {conversation}"));
                }
                if let Err(err) = inner.store.delete(conversation) {
                    return Reply::store_failure(&err);
                }
                inner.sessions.remove(&conversation);
                Reply::direct(EventBody::Conversations {
                    items: inner.store.list(u32::MAX, None),
                })
            }
        }
    }

    /// Build the `hello` handshake: the replay, then `ready`, then
    /// `backends`, plus the subscription the connection pumps afterwards.
    fn hello(&self, inner: &HubInner, protocol: u32, resume_seq: Option<u64>) -> Reply {
        if protocol != PROTOCOL_VERSION {
            tracing::warn!(
                client = protocol,
                daemon = PROTOCOL_VERSION,
                "client speaks another protocol version; answering anyway so it can read ready"
            );
        }
        let replay = match inner.store.events_after(resume_seq) {
            Ok(replay) => replay,
            Err(err) => return Reply::store_failure(&err),
        };
        let seq_head = inner.store.seq_head();
        // Subscribing here, still holding the lock that emit takes, is what
        // makes the replay and the live stream meet exactly once.
        let fanout = self.fanout.subscribe();
        Reply::Attach(Box::new(Attach {
            replay,
            tail: vec![
                ServerEvent::ephemeral(EventBody::Ready {
                    protocol: PROTOCOL_VERSION,
                    seq_head,
                }),
                ServerEvent::ephemeral(EventBody::Backends {
                    items: self.backends.clone(),
                }),
            ],
            seq_head,
            fanout,
        }))
    }

    /// Create the thread an `op:"new"` names.
    fn new_thread(&self, inner: &mut HubInner, meta: ConversationMeta) -> Reply {
        if !self.backends.iter().any(|known| known.id == meta.backend) {
            // Client garbage: no backend has spoken and no thread exists, so
            // there is nothing to persist the failure against.
            return Reply::bad_request(format!("unknown backend {:?}", meta.backend));
        }
        let conversation = meta.id;
        if inner.store.contains(conversation) {
            return Reply::bad_request(format!("conversation {conversation} already exists"));
        }
        if let Err(err) = inner.store.create(meta) {
            return Reply::store_failure(&err);
        }
        inner
            .sessions
            .insert(conversation, Session::new(conversation));
        Reply::direct(EventBody::Conversations {
            items: inner.store.list(u32::MAX, None),
        })
    }

    /// Start the thread's backend, which this phase cannot do.
    ///
    /// The spec puts the spawn on the first `send` rather than on `new`, so
    /// this is exactly where a spawn failure belongs, and it is
    /// conversation-scoped because a thread does exist to file it against.
    fn spawn_backend(&self, inner: &mut HubInner, conversation: Uuid, now: u64) -> Reply {
        let detail = inner
            .store
            .meta(conversation)
            .map(|meta| meta.backend.clone())
            .map_or_else(
                || "no backend is configured for this thread".to_owned(),
                |backend| format!("backend {backend:?} did not start: it is not wired up yet"),
            );
        let body = EventBody::Error {
            kind: ErrorKind::BackendSpawn,
            message: detail,
            fatal: false,
        };
        match Self::emit(inner, &self.fanout, conversation, body, now) {
            Ok(()) => Reply::Direct(Vec::new()),
            Err(err) => Reply::store_failure(&err),
        }
    }

    /// Every persisted event above `seq`, for a pump that fell behind.
    fn refill(&self, seq: u64) -> Result<Vec<ServerEvent>, AskError> {
        self.lock().store.events_after(Some(seq))
    }
}

/// What one client frame produced for the connection that sent it.
enum Reply {
    /// Write these to this connection only.
    Direct(Vec<ServerEvent>),
    /// The `hello` handshake. Boxed because it is much larger than the other
    /// variant and this enum is returned by value on every frame.
    Attach(Box<Attach>),
}

impl Reply {
    /// One ephemeral event for this connection.
    fn direct(body: EventBody) -> Self {
        Self::Direct(vec![ServerEvent::ephemeral(body)])
    }

    /// A connection-scoped `bad_request`.
    fn bad_request(message: String) -> Self {
        Self::Direct(vec![connection_error(ErrorKind::BadRequest, message)])
    }

    /// A connection-scoped `store` error, with the cause chain spelled out.
    fn store_failure(err: &AskError) -> Self {
        tracing::error!(error = %chain(err), "store failure");
        Self::Direct(vec![connection_error(ErrorKind::Store, chain(err))])
    }
}

/// The `hello` handshake, and the live subscription that follows it.
struct Attach {
    replay: Vec<ServerEvent>,
    tail: Vec<ServerEvent>,
    seq_head: u64,
    fanout: broadcast::Receiver<Arc<ServerEvent>>,
}

/// A connection-scoped error event. Never fatal: it kills no thread.
fn connection_error(kind: ErrorKind, message: String) -> ServerEvent {
    ServerEvent::ephemeral(EventBody::Error {
        kind,
        message,
        fatal: false,
    })
}

/// Flatten an error and its causes into one line, since the client sees a
/// string rather than a diagnostic.
fn chain(err: &AskError) -> String {
    let mut text = err.to_string();
    let mut source = std::error::Error::source(err);
    while let Some(cause) = source {
        text.push_str(": ");
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

/// The listener, bound and ready to accept.
pub struct Daemon {
    hub: Arc<Hub>,
    listener: UnixListener,
    socket: PathBuf,
}

impl Daemon {
    /// Bind `socket` and open the store at `state_root`.
    ///
    /// A unix socket outlives the process that bound it, so a crashed run
    /// leaves a file that `bind` would reject with `EADDRINUSE`. Rather than
    /// unlinking blindly, which would steal the socket from a daemon that is
    /// still running, this connects first: a refused connection means the
    /// file is stale and gets removed, and a successful one means somebody
    /// else is serving and this run refuses to start.
    ///
    /// # Errors
    ///
    /// [`AskError::AlreadyRunning`] when another daemon answers on the
    /// socket, [`AskError::RemoveStaleSocket`], [`AskError::Bind`] and
    /// [`AskError::SocketMode`] on the bind path, and whatever
    /// [`Hub::open`] returns.
    pub fn bind(
        socket: PathBuf,
        state_root: PathBuf,
        backends: Vec<BackendInfo>,
    ) -> Result<Self, AskError> {
        let hub = Hub::open(state_root, backends)?;
        clear_socket_path(&socket)?;
        let listener = UnixListener::bind(&socket).map_err(|source| AskError::Bind {
            path: socket.clone(),
            source,
        })?;
        // The mode is the whole access-control story for this protocol.
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).map_err(|source| {
            AskError::SocketMode {
                path: socket.clone(),
                source,
            }
        })?;
        Ok(Self {
            hub,
            listener,
            socket,
        })
    }

    /// Where this daemon is listening.
    #[must_use]
    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Accept connections until the process ends.
    ///
    /// One failed accept does not end the daemon, because the common causes
    /// (a descriptor limit, a peer that vanished between connect and accept)
    /// clear on their own.
    pub async fn serve(self) {
        tracing::info!(socket = %self.socket.display(), "dots-ask listening");
        loop {
            match self.listener.accept().await {
                Ok((stream, _)) => {
                    tokio::spawn(serve_connection(Arc::clone(&self.hub), stream));
                }
                Err(err) => {
                    tracing::warn!(error = %err, "accept failed");
                    tokio::time::sleep(ACCEPT_BACKOFF).await;
                }
            }
        }
    }
}

/// Remove a socket a crashed run left behind, refusing when one is live.
fn clear_socket_path(socket: &Path) -> Result<(), AskError> {
    if !socket.exists() {
        return Ok(());
    }
    if std::os::unix::net::UnixStream::connect(socket).is_ok() {
        return Err(AskError::AlreadyRunning {
            path: socket.to_path_buf(),
        });
    }
    tracing::info!(socket = %socket.display(), "removing a socket left by an earlier run");
    fs::remove_file(socket).map_err(|source| AskError::RemoveStaleSocket {
        path: socket.to_path_buf(),
        source,
    })
}

/// Read frames from one client and write events back to it.
async fn serve_connection(hub: Arc<Hub>, stream: UnixStream) {
    let (reader, writer) = stream.into_split();
    let (outbox, outbox_rx) = mpsc::channel::<Arc<ServerEvent>>(OUTBOX_DEPTH);
    let writer = tokio::spawn(write_events(writer, outbox_rx));
    let mut pump: Option<tokio::task::JoinHandle<()>> = None;

    let mut lines = BufReader::new(reader).lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(err) => {
                tracing::warn!(error = %err, "client read failed");
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let reply = match decode_client_line(&line) {
            Ok(frame) => hub.dispatch(frame),
            Err(message) => {
                tracing::debug!(message, "rejecting a client line");
                Reply::Direct(vec![connection_error(ErrorKind::BadRequest, message)])
            }
        };

        let attach = match reply {
            Reply::Direct(events) => {
                if !send_all(&outbox, events).await {
                    break;
                }
                continue;
            }
            Reply::Attach(attach) => *attach,
        };

        if !send_all(&outbox, attach.replay).await || !send_all(&outbox, attach.tail).await {
            break;
        }
        // A second hello re-attaches. The old pump would keep writing from a
        // stale cursor and duplicate what the new replay just sent.
        if let Some(previous) = pump.replace(tokio::spawn(pump_fanout(
            Arc::clone(&hub),
            attach.fanout,
            outbox.clone(),
            attach.seq_head,
        ))) {
            previous.abort();
        }
    }

    drop(outbox);
    if let Some(pump) = pump {
        pump.abort();
    }
    drop(writer.await);
}

/// Queue events for one connection, reporting whether it is still there.
async fn send_all(outbox: &mpsc::Sender<Arc<ServerEvent>>, events: Vec<ServerEvent>) -> bool {
    for event in events {
        if outbox.send(Arc::new(event)).await.is_err() {
            return false;
        }
    }
    true
}

/// Forward live conversation events to one connection.
///
/// `sent` is the highest `seq` already written, starting at the `seq_head`
/// the replay ended on. Anything at or below it is a duplicate and gets
/// dropped, which is also how a refill after falling behind stays exact.
async fn pump_fanout(
    hub: Arc<Hub>,
    mut fanout: broadcast::Receiver<Arc<ServerEvent>>,
    outbox: mpsc::Sender<Arc<ServerEvent>>,
    mut sent: u64,
) {
    loop {
        match fanout.recv().await {
            Ok(event) => {
                let Some(seq) = event.seq else { continue };
                if seq <= sent {
                    continue;
                }
                sent = seq;
                if outbox.send(event).await.is_err() {
                    return;
                }
            }
            Err(broadcast::error::RecvError::Lagged(missed)) => {
                tracing::warn!(missed, "client fell behind; refilling from the store");
                let refilled = match hub.refill(sent) {
                    Ok(events) => events,
                    Err(err) => {
                        drop(
                            outbox
                                .send(Arc::new(connection_error(ErrorKind::Store, chain(&err))))
                                .await,
                        );
                        return;
                    }
                };
                for event in refilled {
                    let Some(seq) = event.seq else { continue };
                    if seq <= sent {
                        continue;
                    }
                    sent = seq;
                    if outbox.send(Arc::new(event)).await.is_err() {
                        return;
                    }
                }
            }
            Err(broadcast::error::RecvError::Closed) => return,
        }
    }
}

/// Write queued events to the socket, one JSON object per line.
async fn write_events(mut writer: OwnedWriteHalf, mut outbox: mpsc::Receiver<Arc<ServerEvent>>) {
    while let Some(event) = outbox.recv().await {
        let line = match encode_server_line(&event) {
            Ok(line) => line,
            Err(err) => {
                tracing::error!(error = %err, "dropping an event that will not encode");
                continue;
            }
        };
        if let Err(err) = writer.write_all(line.as_bytes()).await {
            tracing::debug!(error = %err, "client went away mid-write");
            return;
        }
    }
}
