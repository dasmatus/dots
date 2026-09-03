//! Append-only JSONL persistence, one file per conversation, plus the index
//! that holds the metadata no event carries.
//!
//! Layout under the state root, which is `$XDG_DATA_HOME/dots-ask` by
//! default:
//!
//! ```text
//! index.json                     the conversations event, verbatim
//! conversations/<uuid>.jsonl     one wire event per line, in seq order
//! ```
//!
//! A transcript line is the wire event byte for byte, so replay is a copy
//! rather than a re-encode and a person can read the file with `jq`.
//!
//! The index is a separate file because nothing in the persisted event set
//! records a thread's backend, model, cwd or title. Those arrive on
//! `op:"new"`, which has no event of its own, so deriving the list from the
//! transcripts alone would lose them.
//!
//! Allocation and append are one operation on purpose. [`Store::record`] is
//! the only way to get a `seq`, and it writes the event before it returns,
//! so the counter cannot run ahead of the file it is meant to describe. That
//! is what makes the numbers a client sees dense, and dense is what makes
//! replay from `resume_seq` gap-free.
//!
//! Durability is deliberately loose: lines are appended without an `fsync`
//! per line, because a turn streams hundreds of deltas and a sync on each
//! would cost more than the transcript is worth. A power cut can lose the
//! tail of a turn. The index is written through a temporary file and renamed,
//! so it is the one file that is never seen half-written.

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use uuid::Uuid;

use crate::proto::{ConversationMeta, EventBody, EventScope, SeqCounter, ServerEvent};
use crate::session::Session;
use crate::AskError;

/// The subdirectory holding one JSONL transcript per conversation.
const TRANSCRIPT_DIR: &str = "conversations";

/// The index file's name under the state root.
const INDEX_FILE: &str = "index.json";

/// What [`Store::open`] recovered from disk.
pub struct Loaded {
    /// The store, with its `seq` counter continuing where the last run left
    /// off.
    pub store: Store,
    /// One session per thread in the index, folded from its transcript.
    pub sessions: BTreeMap<Uuid, Session>,
    /// The `turn_end` events written to close turns a restart killed.
    ///
    /// They are already on disk, so nothing has to send them: recovery
    /// finishes before the listener binds, no client can be attached, and
    /// every client that connects afterwards picks them up in the ordinary
    /// `hello` replay. They are handed back so the caller can say how many
    /// turns a restart cut short.
    pub recovered: Vec<ServerEvent>,
}

/// The conversation store: an index in memory, transcripts on disk.
pub struct Store {
    root: PathBuf,
    index: BTreeMap<Uuid, ConversationMeta>,
    seq: SeqCounter,
}

impl Store {
    /// Open the store at `root`, creating it when it is not there, and close
    /// any turn a previous run left open.
    ///
    /// `now_ms` stamps the recovered `turn_end` events, so a test can hand in
    /// a fixed clock and get a fixed duration.
    ///
    /// # Errors
    ///
    /// [`AskError::CreateDir`] when the directories cannot be made,
    /// [`AskError::StoreRead`] when the index or a transcript cannot be read,
    /// [`AskError::StoreDecode`] when a stored line is not an event this
    /// build understands, and [`AskError::StoreWrite`] when a recovered
    /// `turn_end` cannot be appended.
    pub fn open(root: PathBuf, now_ms: u64) -> Result<Loaded, AskError> {
        create_dir(&root)?;
        create_dir(&root.join(TRANSCRIPT_DIR))?;

        let index = read_index(&root.join(INDEX_FILE))?;
        let mut store = Store {
            root,
            index,
            seq: SeqCounter::default(),
        };

        let mut sessions = BTreeMap::new();
        let mut head = 0_u64;
        for id in store.index.keys().copied().collect::<Vec<_>>() {
            let mut session = Session::new(id);
            for event in store.read_transcript(id)? {
                head = head.max(event.seq.unwrap_or(0));
                session.apply(&event.body);
            }
            sessions.insert(id, session);
        }
        store.seq = SeqCounter::resuming_from(head);

        let mut recovered = Vec::new();
        for (id, session) in &mut sessions {
            if let Some(body) = session.interrupt(now_ms) {
                tracing::warn!(conversation = %id, "closing a turn a restart left open");
                recovered.push(store.record(*id, body, now_ms)?);
            }
        }

        Ok(Loaded {
            store,
            sessions,
            recovered,
        })
    }

    /// The highest `seq` handed out so far, which is what `ready.seq_head`
    /// reports.
    #[must_use]
    pub fn seq_head(&self) -> u64 {
        self.seq.head()
    }

    /// Whether the store knows this thread.
    #[must_use]
    pub fn contains(&self, id: Uuid) -> bool {
        self.index.contains_key(&id)
    }

    /// The metadata for one thread.
    #[must_use]
    pub fn meta(&self, id: Uuid) -> Option<&ConversationMeta> {
        self.index.get(&id)
    }

    /// Turn an event body into a wire event, persisting it when its own
    /// scope says to.
    ///
    /// A connection-scoped body comes back as an ephemeral event with `seq`
    /// and `conversation` null and never touches disk, which is why the
    /// caller can hand any body to this one function. A conversation-scoped
    /// body takes the next `seq`, is appended to the thread's transcript,
    /// and bumps the thread's `updated_ms`, plus its `turns` on a
    /// `turn_end`.
    ///
    /// # Errors
    ///
    /// [`AskError::Encode`] when the event will not serialize, and
    /// [`AskError::StoreWrite`] when the transcript or the index cannot be
    /// written.
    pub fn record(
        &mut self,
        conversation: Uuid,
        body: EventBody,
        now_ms: u64,
    ) -> Result<ServerEvent, AskError> {
        if body.scope() == EventScope::Connection {
            return Ok(ServerEvent::ephemeral(body));
        }

        let closes_turn = matches!(body, EventBody::TurnEnd { .. });
        let event = ServerEvent::persisted(self.seq.allocate(), conversation, body);
        self.append_line(conversation, &event)?;

        if let Some(meta) = self.index.get_mut(&conversation) {
            meta.updated_ms = now_ms;
            if closes_turn {
                meta.turns = meta.turns.saturating_add(1);
                self.write_index()?;
            }
        }
        Ok(event)
    }

    /// Add a thread the client just minted.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreWrite`] when the index cannot be written.
    pub fn create(&mut self, meta: ConversationMeta) -> Result<(), AskError> {
        self.index.insert(meta.id, meta);
        self.write_index()
    }

    /// Remove a thread and its transcript.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreWrite`] when the transcript cannot be removed or the
    /// index cannot be written.
    pub fn delete(&mut self, id: Uuid) -> Result<(), AskError> {
        self.index.remove(&id);
        let path = self.transcript_path(id);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(source) => return Err(AskError::StoreWrite { path, source }),
        }
        self.write_index()
    }

    /// Conversation metadata, newest first, for a `list` frame.
    ///
    /// `before` is an `updated_ms` cursor: only threads strictly older come
    /// back, so paging cannot repeat the row it paged from.
    #[must_use]
    pub fn list(&self, limit: u32, before: Option<u64>) -> Vec<ConversationMeta> {
        let mut rows: Vec<ConversationMeta> = self
            .index
            .values()
            .filter(|meta| before.is_none_or(|cursor| meta.updated_ms < cursor))
            .cloned()
            .collect();
        rows.sort_by(|a, b| b.updated_ms.cmp(&a.updated_ms).then(a.id.cmp(&b.id)));
        rows.truncate(limit as usize);
        rows
    }

    /// Every persisted event above `resume_seq`, across every thread, in
    /// `seq` order.
    ///
    /// This is the `hello` replay. Each transcript is already in `seq` order
    /// because appends happen under the same lock that allocates, so the
    /// merge is a sort of the survivors rather than a re-derivation.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreRead`] or [`AskError::StoreDecode`] when a
    /// transcript will not read back.
    pub fn events_after(&self, resume_seq: Option<u64>) -> Result<Vec<ServerEvent>, AskError> {
        let mut events = Vec::new();
        for id in self.index.keys().copied() {
            events.extend(
                self.read_transcript(id)?
                    .into_iter()
                    .filter(|event| above(event, resume_seq)),
            );
        }
        events.sort_by_key(|event| event.seq);
        Ok(events)
    }

    /// One thread's persisted events above `from_seq`, in `seq` order.
    ///
    /// This is the `open` reply. It sends strictly greater seqs, so a client
    /// that passes the highest it holds is never sent a duplicate.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreRead`] or [`AskError::StoreDecode`] when the
    /// transcript will not read back.
    pub fn conversation_events_after(
        &self,
        id: Uuid,
        from_seq: Option<u64>,
    ) -> Result<Vec<ServerEvent>, AskError> {
        Ok(self
            .read_transcript(id)?
            .into_iter()
            .filter(|event| above(event, from_seq))
            .collect())
    }

    /// Read one thread's transcript in full.
    fn read_transcript(&self, id: Uuid) -> Result<Vec<ServerEvent>, AskError> {
        let path = self.transcript_path(id);
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(source) => return Err(AskError::StoreRead { path, source }),
        };

        let mut events = Vec::new();
        for (offset, line) in BufReader::new(file).lines().enumerate() {
            let line = line.map_err(|source| AskError::StoreRead {
                path: path.clone(),
                source,
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let event = serde_json::from_str(&line).map_err(|source| AskError::StoreDecode {
                path: path.clone(),
                line: offset + 1,
                source,
            })?;
            events.push(event);
        }
        Ok(events)
    }

    /// Append one event to its thread's transcript.
    fn append_line(&self, conversation: Uuid, event: &ServerEvent) -> Result<(), AskError> {
        let line = crate::proto::encode_server_line(event)
            .map_err(|source| AskError::Encode { source })?;
        let path = self.transcript_path(conversation);
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|source| AskError::StoreWrite {
                path: path.clone(),
                source,
            })?;
        file.write_all(line.as_bytes())
            .map_err(|source| AskError::StoreWrite { path, source })
    }

    /// Write the index through a temporary file and rename it into place, so
    /// a crash mid-write leaves the old index rather than half of a new one.
    fn write_index(&self) -> Result<(), AskError> {
        let rows: Vec<&ConversationMeta> = self.index.values().collect();
        let body =
            serde_json::to_vec_pretty(&rows).map_err(|source| AskError::Encode { source })?;

        let final_path = self.root.join(INDEX_FILE);
        let temp_path = self.root.join(format!("{INDEX_FILE}.tmp"));
        fs::write(&temp_path, &body).map_err(|source| AskError::StoreWrite {
            path: temp_path.clone(),
            source,
        })?;
        fs::rename(&temp_path, &final_path).map_err(|source| AskError::StoreWrite {
            path: final_path,
            source,
        })
    }

    /// Where one thread's transcript lives.
    fn transcript_path(&self, id: Uuid) -> PathBuf {
        self.root.join(TRANSCRIPT_DIR).join(format!("{id}.jsonl"))
    }
}

/// Whether an event sits strictly above a resume cursor.
fn above(event: &ServerEvent, cursor: Option<u64>) -> bool {
    match (event.seq, cursor) {
        (Some(seq), Some(cursor)) => seq > cursor,
        (Some(_), None) => true,
        // A transcript should hold no ephemeral event, but a file edited by
        // hand might. Replaying one would put a null seq into a dense space,
        // so it is dropped rather than trusted.
        (None, _) => false,
    }
}

/// Create a directory and everything above it.
fn create_dir(path: &Path) -> Result<(), AskError> {
    fs::create_dir_all(path).map_err(|source| AskError::CreateDir {
        path: path.to_path_buf(),
        source,
    })
}

/// Read the index, treating a missing file as an empty store.
fn read_index(path: &Path) -> Result<BTreeMap<Uuid, ConversationMeta>, AskError> {
    let body = match fs::read_to_string(path) {
        Ok(body) => body,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
        Err(source) => {
            return Err(AskError::StoreRead {
                path: path.to_path_buf(),
                source,
            })
        }
    };
    let rows: Vec<ConversationMeta> =
        serde_json::from_str(&body).map_err(|source| AskError::StoreDecode {
            path: path.to_path_buf(),
            line: 1,
            source,
        })?;
    Ok(rows.into_iter().map(|meta| (meta.id, meta)).collect())
}
