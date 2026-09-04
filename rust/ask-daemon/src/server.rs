//! The unix listener, one newline-delimited JSON loop per client, resume
//! replay, and fan-out to every connected client.
//!
//! More than one client can be attached, and all of them see the same
//! conversation events in the same order. That rests on one rule, worth
//! stating plainly because everything else here follows from it.
//!
//! **Deciding what goes into a connection's queue happens under the same
//! lock that assigns `seq`.** Allocating the number, appending it to the
//! store, and handing it to every attached client are one critical section.
//! So the order a client reads is the order the store holds, an event is
//! never published before it is durable, and nothing can slip between a
//! replay and the subscription that continues it.
//!
//! That is also why the queue is unbounded rather than a broadcast channel.
//! A bounded fan-out makes the enqueue fallible under the lock, and the
//! recovery for a client that fell behind then has to re-read the store
//! outside the lock, which is exactly where a live event can overtake a
//! replay. Unbounded moves the cost to memory instead, so [`MAX_QUEUED`]
//! caps it and a client that has stopped reading is dropped rather than
//! allowed to grow without limit.
//!
//! `hello` is the only automatic replay. `open` answers one connection with
//! the events it asked for and re-sends nothing else, because the client is
//! the one that knows what it already holds.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::artifact::{is_artifact_language, ArtifactStore};
use crate::attach;
use crate::backend::{BackendCommand, BackendHandle, BackendMessage, Registry};
use crate::proto::{
    decode_client_line, encode_server_line, ClientFrame, ConversationMeta, ErrorKind, EventBody,
    SendBlock, ServerEvent, PROTOCOL_VERSION,
};
use crate::session::Session;
use crate::store::Store;
use crate::AskError;

/// The socket's name under `$XDG_RUNTIME_DIR`.
const SOCKET_NAME: &str = "dots-ask.sock";

/// The state root's name under `$XDG_DATA_HOME`.
const STATE_DIR_NAME: &str = "dots-ask";

/// How many events may sit unwritten for one client before it is dropped.
///
/// A client this far behind has stopped reading, and the daemon has no way
/// to help it. Letting the queue grow instead would trade a hung pane for a
/// daemon that runs the machine out of memory.
const MAX_QUEUED: usize = 100_000;

/// How long the accept loop pauses after a failed accept, so a persistent
/// failure such as running out of descriptors cannot spin a core.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(200);

/// Hands out connection ids, which exist so the hub can drop a client from
/// its fan-out when the socket closes.
static NEXT_CLIENT: AtomicU64 = AtomicU64::new(1);

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

/// The state root's name under `$XDG_STATE_HOME`, where `policy.json` lives.
const POLICY_DIR_NAME: &str = "dots-ask";

/// The approval store's file name.
const POLICY_FILE: &str = "policy.json";

/// Where `forever` approvals are kept, per section 5 of the spec:
/// `$XDG_STATE_HOME/dots-ask/policy.json`, falling back to
/// `~/.local/state`.
///
/// Deliberately not the conversation root. Section 4 puts transcripts under
/// `$XDG_DATA_HOME` and section 5 puts approvals under `$XDG_STATE_HOME`,
/// and the split is the right one: a transcript is a record a person may
/// prune, and pruning it must not silently revoke an approval.
///
/// # Errors
///
/// [`AskError::NoDataHome`] when neither variable is set.
pub fn default_policy_path() -> Result<PathBuf, AskError> {
    if let Some(state_home) = std::env::var_os("XDG_STATE_HOME").filter(|dir| !dir.is_empty()) {
        return Ok(PathBuf::from(state_home)
            .join(POLICY_DIR_NAME)
            .join(POLICY_FILE));
    }
    std::env::var_os("HOME")
        .filter(|dir| !dir.is_empty())
        .map(|home| {
            PathBuf::from(home)
                .join(".local")
                .join("state")
                .join(POLICY_DIR_NAME)
                .join(POLICY_FILE)
        })
        .ok_or(AskError::NoDataHome)
}

/// One connection's write queue.
///
/// Cloning is how the hub keeps a handle to a client it can publish to. The
/// depth counter is shared with the clone, so the cap covers everything
/// waiting on that one socket rather than one sender's share of it.
#[derive(Clone)]
struct Outbox {
    events: mpsc::UnboundedSender<Arc<ServerEvent>>,
    depth: Arc<AtomicUsize>,
}

impl Outbox {
    /// Queue one event, reporting whether the client is still worth writing
    /// to.
    ///
    /// False means the socket closed or the client stopped reading, and the
    /// caller drops it from the fan-out.
    fn push(&self, event: Arc<ServerEvent>) -> bool {
        if self.depth.fetch_add(1, Ordering::Relaxed) >= MAX_QUEUED {
            self.depth.fetch_sub(1, Ordering::Relaxed);
            tracing::warn!(cap = MAX_QUEUED, "dropping a client that stopped reading");
            return false;
        }
        if self.events.send(event).is_err() {
            self.depth.fetch_sub(1, Ordering::Relaxed);
            return false;
        }
        true
    }

    /// Queue an ephemeral reply for this connection.
    fn reply(&self, body: EventBody) -> bool {
        self.push(Arc::new(ServerEvent::ephemeral(body)))
    }

    /// Queue a connection-scoped `bad_request`. Never fatal: it kills no
    /// thread.
    fn bad_request(&self, message: String) -> bool {
        tracing::debug!(message, "rejecting a client frame");
        self.reply(EventBody::Error {
            kind: ErrorKind::BadRequest,
            message,
            fatal: false,
        })
    }

    /// Queue a connection-scoped `store` error, with the cause chain spelled
    /// out, because a store failure cannot record itself.
    fn store_failure(&self, err: &AskError) -> bool {
        tracing::error!(error = %chain(err), "store failure");
        self.reply(EventBody::Error {
            kind: ErrorKind::Store,
            message: chain(err),
            fatal: false,
        })
    }
}

/// The artifact half of the daemon, as the hub needs it.
///
/// Two things travel together because they are two halves of one fact: the
/// store is where a page is written and the base is where the same page is
/// read. `base` is `None` when the loopback listener did not bind, which is
/// not fatal: pages are still written and still in the transcript, and the
/// pane simply has nothing to open them with.
pub struct Artifacts {
    /// Where pages are written and what the loopback server resolves against.
    pub store: Arc<ArtifactStore>,
    /// The loopback base URL for this run, or `None` when there is no server.
    pub base: Option<String>,
}

impl Artifacts {
    /// An artifact store with no server behind it.
    ///
    /// What a test wants, and what a daemon whose loopback bind failed falls
    /// back to. Pages are still written and still recorded; nothing can open
    /// one.
    ///
    /// # Errors
    ///
    /// Whatever [`ArtifactStore::open`] returns.
    pub fn unserved(state_root: &Path) -> Result<Self, AskError> {
        Ok(Self {
            store: Arc::new(ArtifactStore::open(state_root)?),
            base: None,
        })
    }
}

/// The shared state every connection works against.
pub struct Hub {
    inner: Mutex<HubInner>,
    registry: Arc<Registry>,
    /// Where a running backend sends what it produced.
    ///
    /// Cloned into each backend at start. The receiving half is taken once,
    /// by [`Daemon::serve`], and driven by [`pump`].
    events: mpsc::UnboundedSender<BackendMessage>,
    /// Where model-written HTML goes, and where it is read back from.
    artifacts: Artifacts,
    /// The state root, which is also the root the attachment and artifact
    /// directories hang off.
    state_root: PathBuf,
}

/// Everything the lock covers.
struct HubInner {
    store: Store,
    sessions: BTreeMap<Uuid, Session>,
    /// Every client that has said `hello`, by connection id.
    attached: BTreeMap<u64, Outbox>,
    /// The backend running each thread that has had a `send`.
    ///
    /// A thread gets an entry on its first `send` and loses it when the
    /// thread is deleted, which is what the spec means by putting the spawn
    /// on the first `send` rather than on `new`.
    running: BTreeMap<Uuid, BackendHandle>,
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
    pub fn open(
        state_root: PathBuf,
        registry: Arc<Registry>,
        artifacts: Artifacts,
    ) -> Result<(Arc<Self>, mpsc::UnboundedReceiver<BackendMessage>), AskError> {
        let loaded = Store::open(state_root.clone(), now_ms())?;
        if !loaded.recovered.is_empty() {
            tracing::info!(
                turns = loaded.recovered.len(),
                "closed turns that a previous run left open"
            );
        }
        let (events, produced) = mpsc::unbounded_channel();
        let hub = Arc::new(Self {
            inner: Mutex::new(HubInner {
                store: loaded.store,
                sessions: loaded.sessions,
                attached: BTreeMap::new(),
                running: BTreeMap::new(),
            }),
            registry,
            events,
            artifacts,
            state_root,
        });
        Ok((hub, produced))
    }

    /// Take one event a backend produced and put it through the same
    /// critical section every other persisted event goes through.
    ///
    /// This is the whole of the backend-to-client path, and it is one
    /// function on purpose. The `await` that waited for the event happened in
    /// [`pump`], outside the lock; everything from stamping the turn to
    /// queueing the event for each attached client happens inside it and
    /// awaits nothing. So a backend's output is ordered against every other
    /// client's replay exactly the way a frame's output already was.
    pub fn absorb(&self, message: BackendMessage) {
        let now = now_ms();
        let mut inner = self.lock();
        let Some(session) = inner.sessions.get(&message.conversation) else {
            tracing::warn!(
                conversation = %message.conversation,
                "a backend produced an event for a thread that is gone"
            );
            return;
        };
        // Stamped before the store sees it, because `turn` is part of the
        // bytes that get written, and dropped here rather than recorded when
        // the session says the event has no turn to belong to.
        let Some(body) = session.adopt(message.body, now) else {
            return;
        };
        // An HTML fence produces a second event, and the page it names has to
        // be on disk before either goes out. Both are built and written here,
        // inside the same lock hold, so they take adjacent seqs and a replay
        // brings back the code block and its artifact in the order they
        // happened. The file write is synchronous, capped by
        // `artifact::MAX_ARTIFACT_BYTES`, and awaits nothing, which is what
        // the whole module rests on.
        let artifact = self.artifact_for(&body, message.conversation);
        let artifact = artifact.and_then(|body| {
            inner
                .sessions
                .get(&message.conversation)
                .and_then(|session| session.adopt(body, now))
        });
        if let Err(err) = Self::emit(&mut inner, message.conversation, body, now) {
            // Nothing to answer to: the event came from a backend, not from
            // a client, so there is no connection whose `store` error this
            // would be. The journal is the only place it can go.
            tracing::error!(error = %chain(&err), "cannot record a backend event");
            return;
        }
        if let Some(body) = artifact {
            if let Err(err) = Self::emit(&mut inner, message.conversation, body, now) {
                tracing::error!(error = %chain(&err), "cannot record an artifact event");
            }
        }
    }

    /// Turn an HTML code block into a written page and the event announcing
    /// it, or `None` for every other event.
    ///
    /// The `code_block` is not replaced. It is the record of what the model
    /// wrote, and a person should be able to read a page's source in the
    /// thread without opening the page.
    ///
    /// A page that will not write is logged and dropped rather than raised as
    /// a conversation `error`: the source is already in the transcript, so
    /// nothing was lost, and an error event here would report a failure the
    /// user did not cause and cannot act on.
    fn artifact_for(&self, body: &EventBody, conversation: Uuid) -> Option<EventBody> {
        let EventBody::CodeBlock {
            language, source, ..
        } = body
        else {
            return None;
        };
        if !is_artifact_language(language.as_deref()) {
            return None;
        }
        match self.artifacts.store.write(conversation, source) {
            Ok(written) => Some(EventBody::Artifact {
                turn: None,
                artifact: written.artifact,
                title: written.title,
                path: written.path,
                revision: written.revision,
                bytes: written.bytes,
            }),
            Err(err) => {
                tracing::warn!(error = %chain(&err), "cannot write an artifact");
                None
            }
        }
    }

    /// Take the lock, recovering from a poisoned one.
    ///
    /// A panic in one connection's critical section must not take the daemon
    /// down with it. The store re-reads its own invariants from disk, and the
    /// worst a poisoned lock can leave behind is a stale index entry, which
    /// the next write corrects.
    fn lock(&self) -> MutexGuard<'_, HubInner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Forget a client that has gone away.
    fn detach(&self, client: u64) {
        self.lock().attached.remove(&client);
    }

    /// Reject a line that is not a frame this daemon can act on.
    ///
    /// Nothing about this reply needs the lock. It targets one connection,
    /// it carries `seq: null` so it can open no hole, and it runs in the
    /// same task as [`Hub::dispatch`] so it cannot land inside that
    /// connection's own replay. It takes the lock anyway, so that the rule
    /// in this module's header holds with no exception attached. An
    /// exception is the part a later phase copies.
    fn reject(&self, outbox: &Outbox, message: String) -> bool {
        let _queueing = self.lock();
        outbox.bad_request(message)
    }

    /// Handle one decoded client frame, queueing whatever it produces.
    ///
    /// This never fails. A store failure becomes a connection-scoped `error`
    /// with kind `store`, because the thing that would have recorded the
    /// failure is the thing that just failed.
    ///
    /// Returns false when the connection should be closed.
    fn dispatch(&self, frame: ClientFrame, client: u64, outbox: &Outbox) -> bool {
        let now = now_ms();
        let mut inner = self.lock();
        match frame {
            ClientFrame::Hello {
                protocol,
                resume_seq,
            } => self.hello(&mut inner, client, outbox, protocol, resume_seq),
            ClientFrame::List { limit, before } => outbox.reply(EventBody::Conversations {
                items: inner.store.list(limit, before),
            }),
            ClientFrame::Open {
                conversation,
                from_seq,
            } => {
                if !inner.store.contains(conversation) {
                    return outbox.bad_request(format!("unknown conversation {conversation}"));
                }
                match inner
                    .store
                    .conversation_events_after(conversation, from_seq)
                {
                    // Queued under the lock, so a live event on the same
                    // thread cannot land in the middle of this replay.
                    Ok(events) => events.into_iter().all(|event| outbox.push(Arc::new(event))),
                    Err(err) => outbox.store_failure(&err),
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
                outbox,
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
                    return outbox.bad_request(format!("unknown conversation {conversation}"));
                }
                if blocks.is_empty() {
                    return outbox.bad_request("send carries no blocks".to_owned());
                }
                for block in &blocks {
                    if let Err(message) = block.validate() {
                        return outbox.bad_request(message);
                    }
                }
                self.send(&mut inner, outbox, conversation, blocks, now)
            }
            ClientFrame::Interrupt { conversation } => {
                let Some(session) = inner.sessions.get_mut(&conversation) else {
                    return outbox.bad_request(format!("unknown conversation {conversation}"));
                };
                // Nothing running is not an error. The pane can fire this at
                // a thread that just finished, and the user's intent is
                // already satisfied.
                let Some(body) = session.interrupt(now) else {
                    return true;
                };
                // Tell the backend before the event goes out, so the CLI is
                // already withdrawing its permission prompt by the time the
                // pane sees the turn close.
                inner.command(conversation, BackendCommand::Interrupt);
                match Self::emit(&mut inner, conversation, body, now) {
                    Ok(()) => true,
                    Err(err) => outbox.store_failure(&err),
                }
            }
            ClientFrame::Permission {
                conversation,
                request,
                decision,
                scope,
                updated_input,
                message,
            } => {
                let Some(session) = inner.sessions.get_mut(&conversation) else {
                    return outbox.bad_request(format!("unknown conversation {conversation}"));
                };
                // An id nothing is waiting on is an argument the daemon
                // cannot resolve, which the scope table calls bad_request.
                if session.resolve_permission(&request).is_none() {
                    return outbox.bad_request(format!(
                        "no permission request {request:?} is open on {conversation}"
                    ));
                }
                // Sending is synchronous and non-blocking, so the relay costs
                // the lock nothing. The harness turns this into a
                // control_response; a provider hands it to policy.rs.
                inner.command(
                    conversation,
                    BackendCommand::Permission {
                        request,
                        decision,
                        scope,
                        updated_input,
                        message,
                    },
                );
                true
            }
            ClientFrame::Delete { conversation } => {
                if !inner.store.contains(conversation) {
                    return outbox.bad_request(format!("unknown conversation {conversation}"));
                }
                if let Err(err) = inner.store.delete(conversation) {
                    return outbox.store_failure(&err);
                }
                // The transcript refers to attachments and to pages, so they
                // go with it. Logged rather than refused: the thread is
                // already gone from the index and a half-done delete that
                // reports failure would leave a person no way to finish it.
                if let Err(err) = attach::forget(&self.state_root, conversation) {
                    tracing::warn!(error = %chain(&err), "cannot remove a thread's attachments");
                }
                if let Err(err) = self.artifacts.store.forget(conversation) {
                    tracing::warn!(error = %chain(&err), "cannot remove a thread's artifacts");
                }
                inner.sessions.remove(&conversation);
                // Dropping the handle would close the channel on its own.
                // Asking first gives the backend the chance to shut its child
                // down rather than have it killed on drop.
                inner.command(conversation, BackendCommand::Shutdown);
                inner.running.remove(&conversation);
                self.registry.forget_session(conversation);
                outbox.reply(EventBody::Conversations {
                    items: inner.store.list(u32::MAX, None),
                })
            }
        }
    }

    /// Answer `hello`: the replay, then `ready`, then `backends`, and only
    /// then does the connection start receiving live events.
    ///
    /// All of it happens in one critical section. Attaching after the replay
    /// is queued is what puts an event in exactly one of the two.
    fn hello(
        &self,
        inner: &mut HubInner,
        client: u64,
        outbox: &Outbox,
        protocol: u32,
        resume_seq: Option<u64>,
    ) -> bool {
        if protocol != PROTOCOL_VERSION {
            tracing::warn!(
                client = protocol,
                daemon = PROTOCOL_VERSION,
                "client speaks another protocol version; answering anyway so it can read ready"
            );
        }
        let replay = match inner.store.events_after(resume_seq) {
            Ok(replay) => replay,
            Err(err) => return outbox.store_failure(&err),
        };
        let alive = replay.into_iter().all(|event| outbox.push(Arc::new(event)))
            && outbox.reply(EventBody::Ready {
                protocol: PROTOCOL_VERSION,
                seq_head: inner.store.seq_head(),
                // Sent here rather than written into the persisted `artifact`
                // event, because the port is picked fresh on every start and
                // a URL in a transcript would be a dead link tomorrow.
                artifact_base: self.artifacts.base.clone(),
            })
            && outbox.reply(EventBody::Backends {
                // Built per handshake rather than cached, so a provider that
                // was `unconfigured` at startup and has since had its
                // credential read reports `ready` to the next client that
                // connects. Nothing here causes a keyring lookup.
                items: self.registry.info(),
            });
        if alive {
            // A second hello replaces the first rather than doubling it.
            inner.attached.insert(client, outbox.clone());
        }
        alive
    }

    /// Persist a conversation event and queue it for every attached client.
    ///
    /// The store is written before the session is folded, and the order is
    /// load-bearing. Phase 1 had it the other way round, which was safe only
    /// because every call site checked `store.contains` or `sessions.get_mut`
    /// first. Phase 2 adds many more emit sites, one of them a pump reading
    /// a channel a deleted thread may still have events on, so the guarantee
    /// is moved into this function rather than left as a rule each new caller
    /// has to know. If `record` refuses, nothing was applied, and a reload
    /// rebuilds exactly the state the transcript describes.
    fn emit(
        inner: &mut HubInner,
        conversation: Uuid,
        body: EventBody,
        now: u64,
    ) -> Result<(), AskError> {
        let event = Arc::new(inner.store.record(conversation, body, now)?);
        if let Some(session) = inner.sessions.get_mut(&conversation) {
            session.apply(&event.body);
        }
        inner
            .attached
            .retain(|_, outbox| outbox.push(Arc::clone(&event)));
        Ok(())
    }

    /// Create the thread an `op:"new"` names.
    fn new_thread(&self, inner: &mut HubInner, outbox: &Outbox, meta: ConversationMeta) -> bool {
        if !self.registry.contains(&meta.backend) {
            // Client garbage: no backend has spoken and no thread exists, so
            // there is nothing to persist the failure against.
            return outbox.bad_request(format!("unknown backend {:?}", meta.backend));
        }
        let conversation = meta.id;
        if inner.store.contains(conversation) {
            return outbox.bad_request(format!("conversation {conversation} already exists"));
        }
        if let Err(err) = inner.store.create(meta) {
            return outbox.store_failure(&err);
        }
        inner
            .sessions
            .insert(conversation, Session::new(conversation));
        outbox.reply(EventBody::Conversations {
            items: inner.store.list(u32::MAX, None),
        })
    }

    /// Record the user's message, start the backend if this is the first
    /// send, and hand it the blocks.
    ///
    /// The `user_message` event goes out first and unconditionally, even when
    /// the backend then fails to start. What the person typed is part of the
    /// thread whether or not anything answered it, and a transcript that
    /// drops the question on a spawn failure is the exact gap the event was
    /// added to close.
    fn send(
        &self,
        inner: &mut HubInner,
        outbox: &Outbox,
        conversation: Uuid,
        blocks: Vec<SendBlock>,
        now: u64,
    ) -> bool {
        // Copied in before anything is recorded, so the path the transcript
        // keeps is one that outlives the pane's scratch directory and one the
        // harness is actually allowed to read. A file that will not copy is
        // the client naming something it cannot back up, which the scope
        // table calls `bad_request`: no turn has started and nothing is worth
        // persisting.
        let blocks = match attach::ingest(&self.state_root, conversation, blocks) {
            Ok(blocks) => blocks,
            Err(err) => return outbox.bad_request(chain(&err)),
        };
        let body = EventBody::UserMessage {
            blocks: blocks.clone(),
            sent_ms: now,
        };
        if let Err(err) = Self::emit(inner, conversation, body, now) {
            return outbox.store_failure(&err);
        }
        if !self.ensure_backend(inner, outbox, conversation, now) {
            return true;
        }
        if !inner.command(conversation, BackendCommand::Send { blocks }) {
            // The task ended between the start and this send, which means
            // the child died. The handle is dropped so the next send tries a
            // fresh one rather than writing into a closed pipe forever.
            inner.running.remove(&conversation);
            return Self::spawn_failed(
                inner,
                outbox,
                conversation,
                "the backend stopped before it could take the message".to_owned(),
                now,
            );
        }
        true
    }

    /// Make sure the thread has a running backend, starting one on the first
    /// `send`.
    ///
    /// The spec puts the spawn on the first `send` rather than on `new`, so
    /// this is where a spawn failure belongs, and it is conversation-scoped
    /// because a thread does exist to file it against.
    ///
    /// Returns false when the backend could not be started, in which case
    /// the `error` event has already been queued.
    fn ensure_backend(
        &self,
        inner: &mut HubInner,
        outbox: &Outbox,
        conversation: Uuid,
        now: u64,
    ) -> bool {
        if inner.running.contains_key(&conversation) {
            return true;
        }
        let Some(meta) = inner.store.meta(conversation).cloned() else {
            return Self::spawn_failed(
                inner,
                outbox,
                conversation,
                "no backend is configured for this thread".to_owned(),
                now,
            );
        };
        // Called under the lock, which is why `Backend::start` is a plain fn
        // that returns as soon as the process is forked or the task is
        // spawned. Nothing it does awaits.
        match self.registry.start(
            &meta.backend,
            conversation,
            meta.model.clone(),
            &meta.cwd,
            attach::conversation_dir(&self.state_root, conversation),
            self.events.clone(),
        ) {
            Ok(handle) => {
                inner.running.insert(conversation, handle);
                true
            }
            Err(detail) => Self::spawn_failed(
                inner,
                outbox,
                conversation,
                format!("backend {:?} did not start: {detail}", meta.backend),
                now,
            ),
        }
    }

    /// Raise the conversation-scoped `backend_spawn` for a thread that has
    /// no backend behind it.
    fn spawn_failed(
        inner: &mut HubInner,
        outbox: &Outbox,
        conversation: Uuid,
        message: String,
        now: u64,
    ) -> bool {
        let body = EventBody::Error {
            kind: ErrorKind::BackendSpawn,
            message,
            fatal: false,
        };
        match Self::emit(inner, conversation, body, now) {
            Ok(()) => false,
            Err(err) => {
                outbox.store_failure(&err);
                false
            }
        }
    }
}

impl HubInner {
    /// Hand one command to a thread's backend, if it has one running.
    ///
    /// Returns false when the thread has no backend or its task has ended.
    /// The send itself is synchronous and non-blocking, which is what lets
    /// this be called from inside the lock.
    fn command(&mut self, conversation: Uuid, command: BackendCommand) -> bool {
        self.running
            .get(&conversation)
            .is_some_and(|handle| handle.send(command))
    }
}

/// Take events off the shared backend channel and put each through
/// [`Hub::absorb`].
///
/// One task for every backend, rather than one per thread, so the ordering
/// of persisted events across threads is decided in a single place. The
/// `await` is here, outside the lock, and `absorb` takes the lock and
/// releases it without awaiting anything.
pub async fn pump(hub: Arc<Hub>, mut produced: mpsc::UnboundedReceiver<BackendMessage>) {
    while let Some(message) = produced.recv().await {
        hub.absorb(message);
    }
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
    /// The backend channel's receiving half, handed to [`pump`] by
    /// [`Daemon::serve`].
    produced: mpsc::UnboundedReceiver<BackendMessage>,
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
    /// [`AskError::SocketMode`] on the bind path, and whatever [`Hub::open`]
    /// returns.
    pub fn bind(
        socket: PathBuf,
        state_root: PathBuf,
        registry: Arc<Registry>,
        artifacts: Artifacts,
    ) -> Result<Self, AskError> {
        let (hub, produced) = Hub::open(state_root, registry, artifacts)?;
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
            produced,
        })
    }

    /// Where this daemon is listening.
    #[must_use]
    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Accept connections until the process ends.
    ///
    /// One failed accept does not end the daemon, because the common causes,
    /// a descriptor limit or a peer that vanished between connect and accept,
    /// clear on their own.
    pub async fn serve(self) {
        tracing::info!(socket = %self.socket.display(), "dots-ask listening");
        tokio::spawn(pump(Arc::clone(&self.hub), self.produced));
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
    let client = NEXT_CLIENT.fetch_add(1, Ordering::Relaxed);
    let (reader, writer) = stream.into_split();
    let (events, queued) = mpsc::unbounded_channel();
    let depth = Arc::new(AtomicUsize::new(0));
    let outbox = Outbox {
        events,
        depth: Arc::clone(&depth),
    };
    let writing = tokio::spawn(write_events(writer, queued, depth));

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

        let alive = match decode_client_line(&line) {
            Ok(frame) => hub.dispatch(frame, client, &outbox),
            Err(message) => hub.reject(&outbox, message),
        };
        if !alive {
            break;
        }
    }

    // A read EOF means this client is done sending. Everything its frames
    // produced was queued while the frame was handled, so dropping the sender
    // here still flushes it: the writer drains before it sees the channel
    // close.
    hub.detach(client);
    drop(outbox);
    drop(writing.await);
}

/// Write queued events to the socket, one JSON object per line.
async fn write_events(
    mut writer: OwnedWriteHalf,
    mut queued: mpsc::UnboundedReceiver<Arc<ServerEvent>>,
    depth: Arc<AtomicUsize>,
) {
    while let Some(event) = queued.recv().await {
        depth.fetch_sub(1, Ordering::Relaxed);
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
