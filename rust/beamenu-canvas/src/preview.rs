//! The preview pane's model: the protocol the launcher speaks, and the HTML
//! every kind of preview turns into.
//!
//! Everything here is pure. The pane's whole job is to look at things the
//! launcher refused to look at, so the reading lives in the binary
//! (`src/main.rs`) and this module takes the bytes it came back with. That is
//! what lets `tests/` cover the interesting half without a filesystem, a
//! compositor or a WebKit process.
//!
//! Markup is generated here and only here, the same rule
//! [`crate::component`] enforces for worker-supplied trees. Nothing the pane
//! is handed reaches the page as markup: a path is escaped before it is
//! written, a text file goes inside a `<pre>` with every angle bracket
//! replaced, and an image travels as a `data:` URI whose payload is base64
//! and therefore cannot close the attribute it sits in.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::ansi::escape_html;

/// Most bytes read from a file to decide what it is and show it as text.
///
/// A preview is a glance, not a reader. Past this the pane would be pushing
/// megabytes of escaped text through `evaluate_javascript` to fill a column
/// nobody is going to scroll to the end of.
pub const MAX_TEXT_BYTES: usize = 128 * 1024;

/// Largest image inlined as a `data:` URI.
///
/// The encoding is a third larger than the file and the whole thing crosses
/// the process boundary as a JavaScript string literal, so a camera raw or a
/// poster-sized PNG is shown as a card rather than decoded.
pub const MAX_IMAGE_BYTES: u64 = 8 * 1024 * 1024;

/// Most directory entries listed.
pub const MAX_LISTING: usize = 200;

/// One line of the launcher-to-pane protocol, newline-delimited JSON.
///
/// A deliberate duplicate of `beamenu::preview::Message`, for the same reason
/// [`crate::config`] duplicates the launcher's config loader: this crate does
/// not depend on that one. `tests/preview.rs` pins the wire format to literal
/// JSON on both sides, so a field renamed on one of them fails a test rather
/// than quietly rendering an empty pane.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Message {
    /// Where the panel is, so the pane can sit exactly on its preview column.
    Metrics {
        width: u32,
        height: u32,
        list_width: u32,
        content_y: u32,
    },
    /// Draw this row's preview.
    Show {
        id: String,
        title: String,
        #[serde(default)]
        subtitle: Option<String>,
        preview: Preview,
        #[serde(default)]
        metadata: Vec<(String, String)>,
    },
    /// Nothing to preview. Take the pane off screen.
    Hide,
    /// The launcher is done. Exit.
    Quit,
}

/// What the highlighted row asked the pane to draw.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Preview {
    /// Whatever is at this path.
    File { path: std::path::PathBuf },
    /// Markdown the launcher already held.
    Markdown { body: String },
    /// A plugin command's own view.
    Command {
        manifest: std::path::PathBuf,
        command: String,
        query: String,
    },
}

/// Where the pane should place itself, in logical pixels.
///
/// The launcher's panel is a layer surface the compositor centres, and so is
/// the pane's. Two centred surfaces of the same size land on top of each
/// other, which is the whole trick: the pane is sized to the *panel*, not to
/// the column, draws nothing outside the column, and needs no idea where on
/// the output either of them ended up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Geometry {
    pub width: u32,
    pub height: u32,
    pub list_width: u32,
    pub content_y: u32,
}

impl Geometry {
    #[must_use]
    pub fn column_width(&self) -> u32 {
        self.width.saturating_sub(self.list_width)
    }

    #[must_use]
    pub fn column_height(&self) -> u32 {
        self.height.saturating_sub(self.content_y)
    }

    /// Whether there is a column worth mapping a surface for.
    #[must_use]
    pub fn usable(&self) -> bool {
        self.column_width() > 0 && self.column_height() > 0
    }
}

/// Parse one line of the protocol.
///
/// A line that does not parse is dropped rather than fatal. The pane sits
/// beside a launcher somebody is typing into; taking the whole pane down over
/// one malformed message would turn a cosmetic bug into a missing feature for
/// the rest of the session.
#[must_use]
pub fn parse_line(line: &str) -> Option<Message> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    serde_json::from_str(line).ok()
}

/// The image MIME type a filename implies, if it implies one.
///
/// By extension rather than by sniffing the bytes, because the answer decides
/// whether the bytes are worth reading at all. Sniffing to find out whether to
/// read is the wrong way round.
#[must_use]
pub fn image_mime(path: &Path) -> Option<&'static str> {
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    Some(match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "avif" => "image/avif",
        // SVG is markup, and markup is exactly what must not reach the page
        // unescaped. As a data: URI in an <img> it is a replaced element:
        // WebKit renders it in an isolated context with no script and no
        // access to this document, which is the only way it is safe to show.
        "svg" => "image/svg+xml",
        _ => return None,
    })
}

/// Whether a filename names an HTML document.
#[must_use]
pub fn is_html(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .is_some_and(|extension| matches!(extension.as_str(), "html" | "htm" | "xhtml"))
}

/// The file a directory should be previewed through, if it is a web app
/// rather than a folder of things.
///
/// A directory holding an `index.html` is a site, and showing it as a list of
/// twelve filenames tells you nothing you wanted to know. The manifest check
/// is what separates a built PWA from a directory that merely happens to
/// contain a stray page; either is worth rendering, so either qualifies.
#[must_use]
pub fn web_app_entry(entries: &[Entry]) -> Option<&'static str> {
    let has = |name: &str| {
        entries
            .iter()
            .any(|entry| entry.name == name && !entry.is_dir)
    };
    if has("index.html") {
        return Some("index.html");
    }
    if has("index.htm") {
        return Some("index.htm");
    }
    None
}

/// Render an HTML document as a document, in a sandboxed frame.
///
/// The pane is a browser engine, so showing a page's source instead of the
/// page would be a strange thing for it to do. What it must not do is run
/// somebody's page with the pane's own privileges, and arrowing past a file
/// in a launcher is not consent to anything.
///
/// So: `srcdoc` rather than a `file:` URL, which gives the document a unique
/// opaque origin with no path back to the filesystem it came from, and a
/// `sandbox` allowing scripts and nothing else. No `allow-same-origin`, so it
/// reaches neither this page nor any storage; no `allow-top-navigation`, so
/// it cannot move the pane; no `allow-forms`, so there is nothing to submit.
/// The page's CSP is inherited, and it forbids every remote fetch, so a
/// document that wanted the network does not get it.
///
/// Scripts are allowed because without them a modern page renders an empty
/// div, which is not a preview of anything. Everything that makes running one
/// dangerous is denied separately above.
///
/// What this cannot do is resolve relative references: a `srcdoc` frame has
/// no base URL, so a page whose CSS and images sit beside it renders with its
/// markup and none of its assets. A page that carries its own styling renders
/// as itself.
#[must_use]
pub fn document_html(source: &str) -> String {
    format!(
        "<iframe class=\"preview-doc\" sandbox=\"allow-scripts\" srcdoc=\"{}\"></iframe>",
        escape_html(source)
    )
}

/// Whether a prefix of a file reads as text.
///
/// A NUL byte is the classic tell and still the reliable one; past that, if
/// the prefix is valid UTF-8 it is worth showing as text. The prefix may cut
/// a multi-byte character in half, so a decode error in the last three bytes
/// is forgiven rather than counted against the file.
#[must_use]
pub fn looks_like_text(bytes: &[u8]) -> bool {
    if bytes.contains(&0) {
        return false;
    }
    match std::str::from_utf8(bytes) {
        Ok(_) => true,
        Err(err) => err.error_len().is_none() && bytes.len() - err.valid_up_to() < 4,
    }
}

/// The valid UTF-8 prefix of `bytes`, for a file whose tail was cut mid-character.
#[must_use]
pub fn text_prefix(bytes: &[u8]) -> &str {
    match std::str::from_utf8(bytes) {
        Ok(text) => text,
        Err(err) => std::str::from_utf8(&bytes[..err.valid_up_to()]).unwrap_or(""),
    }
}

/// A size in bytes, in the units a file manager would use.
///
/// Powers of 1024 with SI-style names, which is what every desktop file
/// manager on this machine shows and therefore what the number beside a file
/// is expected to agree with.
#[must_use]
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];

    if bytes < 1024 {
        return format!("{bytes} B");
    }

    let mut size = bytes as f64;
    let mut unit = 0;
    while size >= 1024.0 && unit + 1 < UNITS.len() {
        size /= 1024.0;
        unit += 1;
    }
    format!("{size:.1} {}", UNITS[unit])
}

/// Base64-encode `bytes`, for a `data:` URI.
///
/// Hand-written rather than pulled from crates.io, which is the opposite of
/// this repo's usual rule. The reason is the build, not the algorithm: this
/// crate is vendored and built offline, so a new dependency means a new
/// lockfile and a new hash for a job that is forty lines of table lookup with
/// no failure mode. `tests/preview.rs` checks it against the RFC 4648
/// vectors, including all three padding cases.
#[must_use]
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = chunk.get(1).copied().map_or(0, u32::from);
        let b2 = chunk.get(2).copied().map_or(0, u32::from);
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
        out.push(ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[((triple >> 6) & 0x3f) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[(triple & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// The `<img>` that shows an image file.
#[must_use]
pub fn image_html(mime: &str, bytes: &[u8]) -> String {
    format!(
        "<div class=\"preview-image\"><img alt=\"\" src=\"data:{};base64,{}\"></div>",
        escape_html(mime),
        base64(bytes)
    )
}

/// The `<pre>` that shows a text file.
#[must_use]
pub fn text_html(text: &str, truncated: bool) -> String {
    let mut out = format!("<pre class=\"preview-text\">{}</pre>", escape_html(text));
    if truncated {
        out.push_str("<p class=\"muted preview-note\">Showing the first ");
        out.push_str(&format_bytes(MAX_TEXT_BYTES as u64));
        out.push_str(".</p>");
    }
    out
}

/// One entry of a directory listing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub is_dir: bool,
}

/// The list that shows a directory.
///
/// Directories first, then names, both case-insensitively, which is the order
/// every file manager settled on and the only one that makes a long listing
/// scannable. `total` is what the directory actually holds, so a listing cut
/// at [`MAX_LISTING`] says so rather than quietly claiming to be everything.
#[must_use]
pub fn listing_html(entries: &[Entry], total: usize) -> String {
    let mut out = String::from("<ul class=\"preview-listing\">");
    for entry in entries {
        let class = if entry.is_dir { "dir" } else { "file" };
        out.push_str(&format!(
            "<li class=\"{class}\">{}{}</li>",
            escape_html(&entry.name),
            if entry.is_dir { "/" } else { "" }
        ));
    }
    out.push_str("</ul>");
    if total > entries.len() {
        out.push_str(&format!(
            "<p class=\"muted preview-note\">{} more.</p>",
            total - entries.len()
        ));
    }
    out
}

/// The card shown for something with no useful visual form: a binary, an
/// image too large to inline, a file that could not be read.
#[must_use]
pub fn card_html(note: &str) -> String {
    format!("<p class=\"muted preview-note\">{}</p>", escape_html(note))
}

/// A date and time from a Unix timestamp, as `DD.MM.YYYY HH:MM:SS`.
///
/// The day-first form with dots is what the desktop's own clock shows, and a
/// preview that disagreed with the panel two centimetres away would be its
/// own small bug. Seconds are kept for the same reason: the clock has them.
///
/// `seconds` is expected to be already shifted into the viewer's timezone;
/// this function does no timezone work of its own, which is what keeps it
/// pure and testable. The shift is `crate::pane`'s job, since finding the
/// offset means asking the C library.
///
/// Hand-rolled for the same reason [`base64`] is: this crate builds offline
/// and vendored, and a date crate is a lockfile change for one format string.
/// The civil-from-days conversion is Howard Hinnant's, the algorithm every
/// date library uses, exact across the whole range a file timestamp can hold.
#[must_use]
pub fn format_timestamp(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let time = seconds.rem_euclid(86_400);
    let (hour, minute, second) = (time / 3600, (time % 3600) / 60, time % 60);

    // days_from_civil, inverted: shift the epoch to 0000-03-01 so leap days
    // land at the end of the cycle and every era is exactly 146097 days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = era * 400 + yoe + i64::from(month <= 2);

    format!("{day:02}.{month:02}.{year:04} {hour:02}:{minute:02}:{second:02}")
}

/// Sort and cap a directory's entries for [`listing_html`].
#[must_use]
pub fn arrange_listing(mut entries: Vec<Entry>) -> (Vec<Entry>, usize) {
    let total = entries.len();
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    entries.truncate(MAX_LISTING);
    (entries, total)
}

/// The strip under the preview: one row per label/value pair, in order.
///
/// Empty input renders nothing at all rather than an empty strip, so a row
/// with no metadata gives the height back to the preview above it.
#[must_use]
pub fn metadata_html(rows: &[(String, String)]) -> String {
    if rows.is_empty() {
        return String::new();
    }
    let mut out = String::from("<dl class=\"preview-meta\">");
    for (label, value) in rows {
        out.push_str(&format!(
            "<div class=\"preview-meta-row\"><dt>{}</dt><dd>{}</dd></div>",
            escape_html(label),
            escape_html(value)
        ));
    }
    out.push_str("</dl>");
    out
}
