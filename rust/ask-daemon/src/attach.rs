//! Attachments: taking a file the pane named into the conversation's own
//! directory, and encoding it the way each backend wants it.
//!
//! **The daemon copies rather than referencing.** A `send` block carries a
//! path, and phase 1 kept that path as-is. Three things make a copy the right
//! answer.
//!
//! A `user_message` is persisted, so the path in it is part of a transcript
//! that outlives the send. The pane's own capture writes to
//! `$XDG_RUNTIME_DIR/dots-ask/`, which is a tmpfs that empties at logout, and
//! a dragged file is somewhere a person may later move or delete. Either way
//! a replayed thread would show a message whose attachment is gone. Copying
//! makes the transcript answer for its own contents, exactly the way the
//! `code_block` event does for a fence.
//!
//! The harness reads attachments off disk rather than getting bytes inline,
//! and its child runs with the thread's `cwd`. An attachment somewhere else
//! needs `--add-dir` to be readable at all, and pointing `--add-dir` at
//! wherever the person dragged from would widen the CLI's reach to a
//! directory nobody chose. One directory per thread, holding exactly what was
//! attached to that thread, is the narrowest thing that works.
//!
//! And deleting a thread should take its attachments with it. They live under
//! the same `$XDG_DATA_HOME/dots-ask/` root as the transcripts for the reason
//! `artifact/mod.rs` sets out: a transcript is a record a person may prune,
//! and everything the record refers to prunes with it.
//!
//! **The copy runs inside the hub's lock**, because a `send` is one frame and
//! the `user_message` that names the copy must not be published before the
//! copy exists. That is why [`MAX_ATTACHMENT_BYTES`] is here: the write is
//! bounded, the same way `store.rs`'s append is.

use std::fs;
use std::path::{Path, PathBuf};

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::proto::{BlockKind, SendBlock};
use crate::AskError;

/// The attachment root's name under the state root.
const ATTACHMENT_DIR_NAME: &str = "attachments";

/// The largest file the daemon will take as an attachment.
///
/// Twenty megabytes is far past what any of the four backends accepts in one
/// message and small enough that the copy is not something the hub's lock
/// notices. A larger file is refused with a `bad_request` naming the cap
/// rather than copied and then rejected by a provider.
pub const MAX_ATTACHMENT_BYTES: u64 = 20 * 1024 * 1024;

/// The image types the Anthropic Messages API accepts as an image block, and
/// the ones the OpenAI chat API takes as a data URL.
///
/// A file outside this set is named to the model as a path rather than
/// inlined. That is honest: a `document` block on the Anthropic API is
/// PDF-only, this daemon has no recorded fixture for one, and sending a block
/// the provider will reject would turn an attachment into a failed turn.
const INLINE_IMAGE_TYPES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/// Where a thread's attachments live.
#[must_use]
pub fn conversation_dir(state_root: &Path, conversation: Uuid) -> PathBuf {
    state_root
        .join(ATTACHMENT_DIR_NAME)
        .join(conversation.to_string())
}

/// Copy every attachment block into the thread's own directory, rewriting the
/// block to name the copy.
///
/// Text blocks pass through untouched. The returned blocks are what the
/// `user_message` event records and what every backend then sees, so the
/// transcript and the backend cannot disagree about which bytes were sent.
///
/// # Errors
///
/// [`AskError::Attachment`] when a block names a path that is missing, is not
/// a regular file, or is over [`MAX_ATTACHMENT_BYTES`], and
/// [`AskError::CreateDir`] or [`AskError::StoreWrite`] when the copy fails.
pub fn ingest(
    state_root: &Path,
    conversation: Uuid,
    blocks: Vec<SendBlock>,
) -> Result<Vec<SendBlock>, AskError> {
    if blocks.iter().all(|block| block.kind == BlockKind::Text) {
        return Ok(blocks);
    }
    let dir = conversation_dir(state_root, conversation);
    fs::create_dir_all(&dir).map_err(|source| AskError::CreateDir {
        path: dir.clone(),
        source,
    })?;
    blocks
        .into_iter()
        .map(|block| match block.kind {
            BlockKind::Text => Ok(block),
            BlockKind::Image | BlockKind::File => take(&dir, block),
        })
        .collect()
}

/// Remove a thread's attachments, called when the thread is deleted.
///
/// # Errors
///
/// [`AskError::StoreWrite`] when the directory will not go away. A directory
/// that is already missing is not an error.
pub fn forget(state_root: &Path, conversation: Uuid) -> Result<(), AskError> {
    let dir = conversation_dir(state_root, conversation);
    match fs::remove_dir_all(&dir) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(source) => Err(AskError::StoreWrite { path: dir, source }),
    }
}

/// Copy one attachment in and rewrite its block.
fn take(dir: &Path, block: SendBlock) -> Result<SendBlock, AskError> {
    let source = block.path.clone().ok_or_else(|| AskError::Attachment {
        path: PathBuf::new(),
        detail: "the block carries no path".to_owned(),
    })?;
    let meta = fs::metadata(&source).map_err(|err| AskError::Attachment {
        path: source.clone(),
        detail: err.to_string(),
    })?;
    if !meta.is_file() {
        return Err(AskError::Attachment {
            path: source,
            detail: "not a regular file".to_owned(),
        });
    }
    if meta.len() > MAX_ATTACHMENT_BYTES {
        return Err(AskError::Attachment {
            path: source,
            detail: format!(
                "{} bytes, over the {MAX_ATTACHMENT_BYTES} byte cap",
                meta.len()
            ),
        });
    }
    // Already inside this thread's own directory, which is what a resend of a
    // replayed message looks like. Copying it onto itself would be a second
    // file with the same bytes and a new name.
    if source.parent() == Some(dir) {
        return Ok(block);
    }
    let target = dir.join(unique_name(&source));
    fs::copy(&source, &target).map_err(|source| AskError::StoreWrite {
        path: target.clone(),
        source,
    })?;
    let mime = block.mime.or_else(|| mime_from_extension(&target));
    Ok(SendBlock {
        kind: block.kind,
        text: block.text,
        path: Some(target),
        mime,
    })
}

/// A name that cannot collide, keeping the original for the model to read.
///
/// The name matters: a model told to look at `flamegraph.svg` has a better
/// chance than one told to look at `4f2c…`. The uuid prefix is what makes two
/// files both called `screenshot.png` land as two files.
fn unique_name(source: &Path) -> String {
    let stem = source
        .file_name()
        .and_then(|name| name.to_str())
        .map_or_else(String::new, sanitize);
    let id = Uuid::new_v4().simple();
    if stem.is_empty() {
        format!("{id}")
    } else {
        format!("{id}-{stem}")
    }
}

/// Reduce a file name to characters that cannot mean anything to a path, a
/// shell or an argv.
///
/// The name comes from a client and ends up inside a directory the harness is
/// given read access to, so it is rebuilt from an allowlist rather than
/// checked against a denylist.
fn sanitize(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    // A leading dot would make the copy a hidden file, and a name of nothing
    // but dots is not a name.
    let trimmed = cleaned.trim_start_matches('.');
    trimmed.chars().take(96).collect()
}

/// The media type for a path, from its extension.
///
/// Only the types a provider can actually inline are named. Everything else
/// is left `None`, which is what routes the block to the "here is a path"
/// wording rather than to a base64 body.
#[must_use]
pub fn mime_from_extension(path: &Path) -> Option<String> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    let mime = match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => return None,
    };
    Some(mime.to_owned())
}

/// Whether a block is an image a provider will take inline.
#[must_use]
pub fn inlines_as_image(block: &SendBlock) -> bool {
    if block.kind != BlockKind::Image {
        return false;
    }
    let mime = block
        .mime
        .clone()
        .or_else(|| block.path.as_deref().and_then(mime_from_extension));
    mime.is_some_and(|mime| INLINE_IMAGE_TYPES.contains(&mime.as_str()))
}

/// The media type a provider is told, defaulting to PNG for an image block
/// the client left untyped.
#[must_use]
pub fn image_mime(block: &SendBlock) -> String {
    block
        .mime
        .clone()
        .or_else(|| block.path.as_deref().and_then(mime_from_extension))
        .unwrap_or_else(|| "image/png".to_owned())
}

/// Read one attachment and base64 it.
///
/// # Errors
///
/// [`AskError::Attachment`] when the file cannot be read. The caller turns
/// that into a text line naming the path rather than failing the turn: an
/// attachment that will not read is a worse answer than a mention of it.
pub fn base64_of(path: &Path) -> Result<String, AskError> {
    let bytes = fs::read(path).map_err(|err| AskError::Attachment {
        path: path.to_path_buf(),
        detail: err.to_string(),
    })?;
    Ok(STANDARD.encode(bytes))
}

/// How the model is told about an attachment it gets no bytes for.
///
/// The wording names the kind and the path, so a harness model can `Read` it
/// and a provider model can hand the path to an MCP tool that reads files.
/// Nothing in this daemon reads a file on a model's behalf.
#[must_use]
pub fn mention(block: &SendBlock) -> String {
    format!(
        "[attached {}: {}]",
        block.kind,
        block
            .path
            .as_ref()
            .map_or_else(String::new, |path| path.display().to_string())
    )
}

/// The Anthropic Messages API content blocks for one user message.
///
/// An image becomes a base64 `image` block, which is the only attachment
/// shape section 3's mapping table can claim for this provider: `document` is
/// PDF-only and unrecorded. Everything else is named as a path.
#[must_use]
pub fn anthropic_content(blocks: &[SendBlock]) -> Vec<Value> {
    blocks
        .iter()
        .map(|block| match block.kind {
            BlockKind::Text => json!({
                "type": "text",
                "text": block.text.clone().unwrap_or_default(),
            }),
            _ => inline_or_mention(block, |mime, data| {
                json!({
                    "type": "image",
                    "source": {"type": "base64", "media_type": mime, "data": data},
                })
            }),
        })
        .collect()
}

/// The OpenAI chat completion content parts for one user message.
///
/// An image becomes an `image_url` part carrying a `data:` URL, which is the
/// shape every OpenAI-compatible server that supports images accepts. There
/// is no upload endpoint in this daemon and there will not be one: uploading
/// would put a copy of the file on somebody else's disk under a handle
/// nothing here tracks.
#[must_use]
pub fn openai_content(blocks: &[SendBlock]) -> Vec<Value> {
    blocks
        .iter()
        .map(|block| match block.kind {
            BlockKind::Text => json!({
                "type": "text",
                "text": block.text.clone().unwrap_or_default(),
            }),
            _ => inline_or_mention(block, |mime, data| {
                json!({
                    "type": "image_url",
                    "image_url": {"url": format!("data:{mime};base64,{data}")},
                })
            }),
        })
        .collect()
}

/// The ollama `/api/chat` message for one user message.
///
/// ollama takes images as a sibling `images` array of bare base64 strings,
/// with no media type and no data URL prefix, rather than as content parts.
/// The spec's section 3 had no attachment row for any backend; this is the
/// row phase 5 added for this one.
#[must_use]
pub fn ollama_message(blocks: &[SendBlock]) -> Value {
    let mut lines = Vec::new();
    let mut images = Vec::new();
    for block in blocks {
        match block.kind {
            BlockKind::Text => lines.push(block.text.clone().unwrap_or_default()),
            _ => {
                let inlined = inlines_as_image(block)
                    .then(|| block.path.as_deref().and_then(|path| base64_of(path).ok()))
                    .flatten();
                match inlined {
                    Some(data) => images.push(Value::String(data)),
                    None => lines.push(mention(block)),
                }
            }
        }
    }
    let mut message = json!({"role": "user", "content": lines.join("\n")});
    if !images.is_empty() {
        message["images"] = Value::Array(images);
    }
    message
}

/// Build a provider's image part, falling back to a text mention when the
/// file is not an inlinable image or will not read.
fn inline_or_mention(block: &SendBlock, part: impl Fn(String, String) -> Value) -> Value {
    let data = inlines_as_image(block)
        .then(|| block.path.as_deref().and_then(|path| base64_of(path).ok()))
        .flatten();
    match data {
        Some(data) => part(image_mime(block), data),
        None => json!({"type": "text", "text": mention(block)}),
    }
}
