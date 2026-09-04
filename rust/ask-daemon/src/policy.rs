//! Deny by default, and the store of the decisions a person made earlier.
//!
//! Nothing runs without a decision somebody made, or a rule somebody wrote
//! down before. [`Policy::decide`] answers one of three things and there is
//! no fourth: run it, refuse it, or ask.
//!
//! What this module does not answer is whether the tool exists. A prompt for
//! a tool nobody configured is a prompt whose only correct answer is no, so
//! that refusal happens before a call gets here, in `provider.rs`, which is
//! the code that knows what the MCP servers expose. Keeping the two apart is
//! deliberate: an earlier version held both, and its name gate was disabled
//! by exactly the empty set that should have refused everything.
//!
//! ## What a decision is keyed by
//!
//! Backend, tool name, the conversation's working directory, and a
//! normalized form of the tool's arguments. All four, because dropping any
//! one of them makes "allow always" mean more than the person meant:
//!
//! - Without the arguments, allowing `Bash(git status)` once would allow
//!   `Bash(rm -rf ~)` forever.
//! - Without the `cwd`, an approval granted in one checkout would carry into
//!   another, which section 5 of the spec rules out by name.
//! - Without the backend, a rule written for the harness would authorize a
//!   raw provider calling an MCP tool of the same name.
//!
//! The normalized form is the arguments re-serialized with their keys
//! sorted, so `{"a":1,"b":2}` and `{"b":2,"a":1}` are one rule rather than
//! two, and a whitespace change in the model's JSON does not silently open a
//! second one. It is stored as the JSON itself rather than as a digest,
//! because section 5 promises a `forever` entry is plain JSON a person can
//! read and delete by hand, and a digest is neither.
//!
//! ## Where they live
//!
//! `once` and `session` decisions stay in memory and die with the
//! conversation or the daemon. `forever` decisions are the only ones that
//! reach disk, at the path the caller hands [`Policy::open`]. They never go
//! into a conversation transcript: that file is a record of what happened,
//! not a store of what is permitted, and a person pruning old conversations
//! must not be silently revoking approvals at the same time.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::proto::{PermissionDecision, PermissionScope};
use crate::AskError;

/// What the daemon does with one tool call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// A rule already allows exactly this call.
    Allow,
    /// A rule already refuses it, or nothing can run it at all.
    Deny,
    /// Nothing decides it, so the pane raises a `permission_request`.
    Ask,
}

/// One rule's identity: everything that has to match for it to apply.
///
/// Ordered fields rather than a hash, so `policy.json` sorts the way a
/// person would sort it by hand.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PolicyKey {
    /// The backend id the rule was written under.
    pub backend: String,
    /// The tool's own name.
    pub tool: String,
    /// The conversation's working directory when the rule was written.
    pub cwd: PathBuf,
    /// The tool arguments, re-serialized with keys sorted.
    pub arguments: String,
}

impl PolicyKey {
    /// Build the key for one call.
    ///
    /// `input` is whatever the backend sent, carried through untyped, so
    /// this is the one place it is put into a canonical form.
    #[must_use]
    pub fn new(backend: &str, tool: &str, cwd: &Path, input: &Value) -> Self {
        Self {
            backend: backend.to_owned(),
            tool: tool.to_owned(),
            cwd: cwd.to_path_buf(),
            arguments: normalize_arguments(input),
        }
    }
}

/// The tool arguments as one canonical string.
///
/// `serde_json::Value` keeps objects in a `Map` that preserves insertion
/// order unless the `preserve_order` feature is off, which it is here, so a
/// re-serialize is already key-sorted. Doing it through `to_string` rather
/// than trusting the model's own bytes is what makes two spellings of the
/// same arguments one rule.
fn normalize_arguments(input: &Value) -> String {
    serde_json::to_string(input).unwrap_or_else(|_| {
        // Only a non-finite float reaches this, and no tool takes one. The
        // fallback deliberately cannot collide with a real serialization,
        // so an unserializable argument set matches no stored rule and the
        // call falls through to Ask rather than to a stale Allow.
        format!("\u{0}unserializable:{input:?}")
    })
}

/// What `policy.json` holds.
///
/// A list rather than a map, because a [`PolicyKey`] is a struct and JSON
/// object keys are strings. A person reading the file sees one object per
/// rule with its four fields spelled out, which is the readability section 5
/// promises.
#[derive(Debug, Default, Serialize, Deserialize)]
struct PolicyFile {
    /// The `forever` rules, in key order.
    #[serde(default)]
    rules: Vec<PolicyRule>,
}

/// One persisted `forever` rule.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PolicyRule {
    /// What the rule matches.
    #[serde(flatten)]
    key: PolicyKey,
    /// Allow or deny.
    decision: PermissionDecision,
}

/// Deny by default, plus the rules that say otherwise.
pub struct Policy {
    path: PathBuf,
    forever: BTreeMap<PolicyKey, PermissionDecision>,
    session: BTreeMap<(Uuid, PolicyKey), PermissionDecision>,
}

impl Policy {
    /// Load the `forever` rules from `path`, treating a missing file as an
    /// empty rule set.
    ///
    /// A missing file is the normal first-run state and is not an error. A
    /// file that will not parse is, because silently starting with no rules
    /// would revoke every approval a person granted and give no sign of it.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreRead`] when the file exists and cannot be read,
    /// [`AskError::StoreDecode`] when it is not a policy file this build
    /// understands.
    pub fn open(path: PathBuf) -> Result<Self, AskError> {
        let forever = match fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str::<PolicyFile>(&text)
                .map_err(|source| AskError::StoreDecode {
                    path: path.clone(),
                    line: 1,
                    source,
                })?
                .rules
                .into_iter()
                .map(|rule| (rule.key, rule.decision))
                .collect(),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(source) => {
                return Err(AskError::StoreRead {
                    path: path.clone(),
                    source,
                })
            }
        };
        Ok(Self {
            path,
            forever,
            session: BTreeMap::new(),
        })
    }

    /// Where the `forever` rules are kept.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// What to do with one tool call.
    ///
    /// A `session` rule wins over a `forever` one, because it is the more
    /// recent thing the person said, and with neither the answer is
    /// [`Verdict::Ask`].
    ///
    /// Whether the tool exists at all is deliberately not asked here. This
    /// module knows what a person decided; it does not know what any backend
    /// can run, and an earlier version that tried to hold both had a name
    /// gate that an empty set silently disabled. `provider.rs` settles
    /// existence before it asks this, so a name nothing exposes is refused
    /// without a prompt and never reaches these rules.
    #[must_use]
    pub fn decide(&self, conversation: Uuid, key: &PolicyKey) -> Verdict {
        let found = self
            .session
            .get(&(conversation, key.clone()))
            .or_else(|| self.forever.get(key));
        match found {
            Some(PermissionDecision::Allow) => Verdict::Allow,
            Some(PermissionDecision::Deny) => Verdict::Deny,
            None => Verdict::Ask,
        }
    }

    /// Record what a person just decided.
    ///
    /// [`PermissionScope::Once`] stores nothing: the decision applies to the
    /// call that is already in flight and to nothing after it.
    /// [`PermissionScope::Session`] stays in memory.
    /// [`PermissionScope::Forever`] is written to disk before this returns,
    /// so a decision survives a daemon that dies a moment later.
    ///
    /// # Errors
    ///
    /// [`AskError::StoreWrite`] when `policy.json` cannot be written. The
    /// in-memory rule is kept anyway, so a disk failure downgrades a
    /// `forever` to a `session` rather than losing the decision outright.
    pub fn remember(
        &mut self,
        conversation: Uuid,
        key: PolicyKey,
        decision: PermissionDecision,
        scope: PermissionScope,
    ) -> Result<(), AskError> {
        match scope {
            PermissionScope::Once => Ok(()),
            PermissionScope::Session => {
                self.session.insert((conversation, key), decision);
                Ok(())
            }
            PermissionScope::Forever => {
                self.session.insert((conversation, key.clone()), decision);
                self.forever.insert(key, decision);
                self.write()
            }
        }
    }

    /// Drop every `session` rule for one conversation.
    ///
    /// The conversation ended or was deleted, so the rules it carried have
    /// nothing left to apply to.
    pub fn forget_session(&mut self, conversation: Uuid) {
        self.session.retain(|(id, _), _| *id != conversation);
    }

    /// How many `forever` rules are loaded, which is what a test asserts a
    /// reload against.
    #[must_use]
    pub fn forever_len(&self) -> usize {
        self.forever.len()
    }

    /// Write `policy.json` through a temporary file and a rename.
    ///
    /// The same trick `store.rs` uses on its index, for the same reason: a
    /// half-written permission store is worse than a stale one, because the
    /// half that survives decides what runs.
    fn write(&self) -> Result<(), AskError> {
        let file = PolicyFile {
            rules: self
                .forever
                .iter()
                .map(|(key, decision)| PolicyRule {
                    key: key.clone(),
                    decision: *decision,
                })
                .collect(),
        };
        let text =
            serde_json::to_string_pretty(&file).map_err(|source| AskError::Encode { source })?;

        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|source| AskError::CreateDir {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let temp = self.path.with_extension("json.tmp");
        fs::write(&temp, text).map_err(|source| AskError::StoreWrite {
            path: temp.clone(),
            source,
        })?;
        fs::rename(&temp, &self.path).map_err(|source| AskError::StoreWrite {
            path: self.path.clone(),
            source,
        })
    }
}
