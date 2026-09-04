//! Model-written HTML pages: where they are kept, how they are addressed,
//! and what the browser is allowed to do with one.
//!
//! Quickshell cannot host QtWebEngine, so an HTML page never renders in the
//! pane. It opens in a separate Chromium window instead, which is the whole
//! reason this module exists and the whole reason it is careful.
//!
//! **The threat model here is not the pane's.** `render.rs` gets to be
//! relaxed because its output lands in a QML `Text` element, which runs no
//! script and fetches nothing but images. A real browser runs script, resolves
//! `fetch`, follows `<meta http-equiv="refresh">` and loads anything a URL
//! names. An artifact is a page some model wrote after reading a file, a web
//! page or a tool result, any of which a third party may have written. So the
//! page is treated as hostile markup that a browser will execute, and the
//! containment is written down in [`serve::CSP`] rather than inferred from the
//! markup being clean. Section 5 of the spec carries the same decision in
//! prose.
//!
//! **Where they live: `$XDG_DATA_HOME/dots-ask/artifacts/<conversation>/`,
//! next to the transcripts.** The spec's split is that
//! `$XDG_DATA_HOME` holds a record a person may prune and `$XDG_STATE_HOME`
//! holds a decision they made. An artifact is the first: it is content of a
//! persisted `artifact` event, it is replayed with the thread, and it must
//! die with the thread. Putting it under the state root would mean deleting a
//! conversation left its pages behind, and putting it in the runtime
//! directory would mean a transcript full of links that stop working at the
//! next logout.
//!
//! **One artifact per conversation, revised in place.** The brief asks that
//! regenerating an artifact reload the window that is already open rather than
//! launch a second one, and a stable URL is the only thing that makes that
//! true without the daemon driving the browser. So a thread mints one token
//! the first time the model writes HTML, and every later page overwrites the
//! same file and raises `revision`. Nothing is lost: the `code_block` event
//! beside each `artifact` still carries the source of every version in the
//! transcript.
//!
//! **The token is the access control, not the port.** Every process on this
//! machine can connect to a loopback listener and can scan for it, so the port
//! cannot be a secret and is not treated as one. The path is: 122 bits from a
//! v4 uuid, minted per thread, never logged, and known only to a client that
//! read the `artifact` event off the 0600 socket.

pub mod serve;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use uuid::Uuid;

use crate::AskError;

/// The artifact root's name under the state root.
const ARTIFACT_DIR_NAME: &str = "artifacts";

/// The largest page the daemon will put on disk and serve.
///
/// A cap exists because the write happens inside the hub's critical section,
/// for the same reason [`crate::store::Store::record`]'s append does: an
/// artifact is part of one persisted frame and has to be durable before the
/// event announcing it reaches a client. Four megabytes of HTML is far more
/// than a model emits in a fence and small enough that the write is not
/// something a reader could notice.
pub const MAX_ARTIFACT_BYTES: usize = 4 * 1024 * 1024;

/// The fence languages that become an artifact rather than a code block.
///
/// Only HTML leaves the pane. Markdown, code, SVG and images all render
/// natively in a QML `Text`, and sending them to a browser would trade a
/// working renderer for a window and a security question.
const ARTIFACT_LANGUAGES: [&str; 2] = ["html", "htm"];

/// Whether a fence with this language tag becomes an artifact.
#[must_use]
pub fn is_artifact_language(language: Option<&str>) -> bool {
    language.is_some_and(|tag| {
        let tag = tag.trim().to_ascii_lowercase();
        ARTIFACT_LANGUAGES.contains(&tag.as_str())
    })
}

/// What one write produced, which is exactly what the `artifact` event
/// carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Written {
    /// The unguessable id the page is served under.
    pub artifact: String,
    /// Where the file is.
    pub path: PathBuf,
    /// 1 on the first write, one higher on every rewrite.
    pub revision: u32,
    /// The file's size.
    pub bytes: u64,
    /// The page's own `<title>`, when it has one.
    pub title: Option<String>,
}

/// One artifact the server can answer for.
#[derive(Debug, Clone)]
struct Entry {
    conversation: Uuid,
    path: PathBuf,
    revision: u32,
}

/// The artifacts on disk, and the map the loopback server resolves against.
///
/// Shared between the hub, which writes, and the server task, which reads.
/// The lock is a `std::sync::Mutex` and every use of it is a map lookup with
/// no `await` inside, which is what lets the hub take it from inside its own
/// critical section and the server take it from inside an async handler
/// without making that future non-`Send`.
#[derive(Debug)]
pub struct ArtifactStore {
    root: PathBuf,
    live: Mutex<Live>,
}

/// Everything the lock covers.
#[derive(Debug, Default)]
struct Live {
    /// By token, which is what a request names.
    entries: BTreeMap<String, Entry>,
    /// By thread, which is what a write names.
    tokens: BTreeMap<Uuid, String>,
}

impl ArtifactStore {
    /// Open the artifact root under `state_root` and adopt what is already
    /// there.
    ///
    /// The scan is what keeps a replayed `artifact` event openable across a
    /// daemon restart. The token lives in the file name rather than in a
    /// sidecar index, so the directory alone is enough to rebuild the map,
    /// and a transcript and a directory cannot disagree about it.
    ///
    /// # Errors
    ///
    /// [`AskError::CreateDir`] when the root cannot be made, and
    /// [`AskError::StoreRead`] when it cannot be walked.
    pub fn open(state_root: &Path) -> Result<Self, AskError> {
        let root = state_root.join(ARTIFACT_DIR_NAME);
        fs::create_dir_all(&root).map_err(|source| AskError::CreateDir {
            path: root.clone(),
            source,
        })?;
        let store = Self {
            root,
            live: Mutex::new(Live::default()),
        };
        store.adopt_existing()?;
        Ok(store)
    }

    /// The directory every artifact must sit inside.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Write one page for a thread, minting its token on the first call.
    ///
    /// # Errors
    ///
    /// [`AskError::CreateDir`] or [`AskError::StoreWrite`] when the file
    /// cannot be written, and [`AskError::ArtifactTooLarge`] when the page is
    /// over [`MAX_ARTIFACT_BYTES`].
    pub fn write(&self, conversation: Uuid, html: &str) -> Result<Written, AskError> {
        if html.len() > MAX_ARTIFACT_BYTES {
            return Err(AskError::ArtifactTooLarge {
                bytes: html.len(),
                cap: MAX_ARTIFACT_BYTES,
            });
        }
        let mut live = self.lock();
        let token = match live.tokens.get(&conversation) {
            Some(token) => token.clone(),
            None => {
                let token = mint_token();
                live.tokens.insert(conversation, token.clone());
                token
            }
        };
        let dir = self.root.join(conversation.to_string());
        fs::create_dir_all(&dir).map_err(|source| AskError::CreateDir {
            path: dir.clone(),
            source,
        })?;
        let path = dir.join(format!("{token}.html"));
        fs::write(&path, html).map_err(|source| AskError::StoreWrite {
            path: path.clone(),
            source,
        })?;
        let revision = live
            .entries
            .get(&token)
            .map_or(1, |entry| entry.revision.saturating_add(1));
        live.entries.insert(
            token.clone(),
            Entry {
                conversation,
                path: path.clone(),
                revision,
            },
        );
        Ok(Written {
            artifact: token,
            path,
            revision,
            bytes: html.len() as u64,
            title: title_of(html),
        })
    }

    /// The file one request names, or `None` when nothing is registered under
    /// that pair.
    ///
    /// **No filesystem path is built from the request.** The token is looked
    /// up in the map and the answer is a path this process wrote itself, so
    /// there is no string concatenation for a `..` to travel through. The
    /// containment check below is the second line rather than the first, and
    /// it is there because a map that is wrong is a bug this should refuse
    /// rather than serve.
    #[must_use]
    pub fn locate(&self, conversation: Uuid, token: &str) -> Option<Located> {
        let live = self.lock();
        let entry = live.entries.get(token)?;
        if entry.conversation != conversation {
            return None;
        }
        if !self.contains(&entry.path) {
            tracing::error!(
                path = %entry.path.display(),
                "refusing an artifact that is registered outside the artifact root"
            );
            return None;
        }
        Some(Located {
            path: entry.path.clone(),
            revision: entry.revision,
        })
    }

    /// The revision a token stands at, which is what the reload shim polls.
    #[must_use]
    pub fn revision(&self, token: &str) -> Option<u32> {
        self.lock().entries.get(token).map(|entry| entry.revision)
    }

    /// Drop a thread's artifact from the map and from disk.
    ///
    /// Called when the thread is deleted, so `op:"delete"` removes the
    /// transcript, the attachments and the pages in one gesture rather than
    /// leaving a model's output behind after the conversation that produced
    /// it is gone.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreWrite`] when the directory will not go away. A
    /// directory that is already missing is not an error.
    pub fn forget(&self, conversation: Uuid) -> Result<(), AskError> {
        let mut live = self.lock();
        if let Some(token) = live.tokens.remove(&conversation) {
            live.entries.remove(&token);
        }
        drop(live);
        let dir = self.root.join(conversation.to_string());
        match fs::remove_dir_all(&dir) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(AskError::StoreWrite { path: dir, source }),
        }
    }

    /// Whether a path sits inside the artifact root.
    ///
    /// Compared after `canonicalize` on both sides so a symlink pointing out
    /// of the root fails this rather than passing on its spelling. A path
    /// that cannot be canonicalized, which means it does not exist, fails
    /// too: serving a file this cannot resolve is not something to guess at.
    fn contains(&self, path: &Path) -> bool {
        let (Ok(root), Ok(real)) = (self.root.canonicalize(), path.canonicalize()) else {
            return false;
        };
        real.starts_with(&root)
    }

    /// Take the lock, recovering from a poisoned one, the same way the hub
    /// does: a panic in one request must not take artifacts down for the rest
    /// of the session.
    fn lock(&self) -> MutexGuard<'_, Live> {
        self.live.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Read the artifact root back into the map at startup.
    fn adopt_existing(&self) -> Result<(), AskError> {
        let threads = fs::read_dir(&self.root).map_err(|source| AskError::StoreRead {
            path: self.root.clone(),
            source,
        })?;
        let mut live = self.lock();
        for thread in threads {
            let thread = thread.map_err(|source| AskError::StoreRead {
                path: self.root.clone(),
                source,
            })?;
            let dir = thread.path();
            let Some(conversation) = dir
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| Uuid::parse_str(name).ok())
            else {
                continue;
            };
            let pages = fs::read_dir(&dir).map_err(|source| AskError::StoreRead {
                path: dir.clone(),
                source,
            })?;
            for page in pages.flatten() {
                let path = page.path();
                let Some(token) = path
                    .file_stem()
                    .and_then(|stem| stem.to_str())
                    .filter(|stem| is_token(stem))
                    .map(str::to_owned)
                else {
                    continue;
                };
                if path.extension().and_then(|ext| ext.to_str()) != Some("html") {
                    continue;
                }
                live.tokens.insert(conversation, token.clone());
                live.entries.insert(
                    token,
                    Entry {
                        conversation,
                        path,
                        // A restart cannot know how many times the model
                        // rewrote this page, and does not need to: the number
                        // only has to rise for an open window to reload, and
                        // no window survived the restart either.
                        revision: 1,
                    },
                );
            }
        }
        Ok(())
    }
}

/// Where one request resolved to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Located {
    /// The file to serve.
    pub path: PathBuf,
    /// The revision the reload shim compares against.
    pub revision: u32,
}

/// A fresh artifact id: 32 lowercase hex characters, 122 bits of it random.
fn mint_token() -> String {
    Uuid::new_v4().simple().to_string()
}

/// Whether a string is shaped like a token this process minted.
///
/// The request path is checked against this before anything looks it up, so
/// a request carrying `..`, a slash, a percent escape or anything else that
/// is not hex is refused on its shape rather than on a failed lookup.
#[must_use]
pub fn is_token(candidate: &str) -> bool {
    candidate.len() == 32 && candidate.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The page's own `<title>`, for the pane's artifact card.
///
/// A deliberately small scan rather than a parser: this is a label in a card,
/// the text is escaped by the pane before it is drawn, and pulling an HTML
/// parser into the tree to read one element would be the wrong trade.
fn title_of(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let open = lower.find("<title")?;
    let start = open + lower[open..].find('>')? + 1;
    let end = start + lower[start..].find("</title>")?;
    let title = html.get(start..end)?.trim();
    if title.is_empty() || title.chars().count() > 200 {
        return None;
    }
    Some(title.to_owned())
}
