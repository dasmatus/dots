//! Markdown to display-ready blocks, so the QML pane stays a dumb renderer.
//!
//! `pulldown-cmark` finds the fenced code in a settled assistant message and
//! `syntect` colours it. Both outputs, `code_block.html` and `diff.html`,
//! are the small rich-text subset a QML `Text` element draws with
//! `Text.RichText`. Quickshell cannot host `QtWebEngine`, so this is never a
//! web page and never will be.
//!
//! ## Why the tag allowlist is the point of this module
//!
//! The pane feeds these two strings straight into `Text.RichText` and has no
//! way to police them. Qt's rich text runs no script and loads no
//! stylesheet, so this is not code execution. It does resolve
//! `<img src="...">` through `QQuickPixmap`, which handles `http(s):` and
//! `file:`, and `Text` has no switch to turn image loading off. So a model
//! that writes a raw `<img src=http://…>` into its answer could make the
//! pane tell a remote host that it rendered, or pull a local file into the
//! view. The QML side cannot mitigate that even in principle.
//!
//! Every string that reaches the output therefore goes through
//! [`escape_text`] first, and the emitted markup uses a fixed tag set that
//! has no `img`, no `a`, and no `src` or `href` attribute anywhere. There is
//! no pass-through path: nothing here copies a byte of model output into the
//! output as markup rather than as escaped text. `tests/render.rs` feeds
//! hostile markdown through and asserts none of it survives.
//!
//! Colours come off the syntect theme and are written into `style` on a
//! `span`, rather than named by a class the pane would have to know about.
//! That keeps the pane from carrying a second copy of the palette.

use std::fmt::Write as _;
use std::sync::OnceLock;

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use similar::{ChangeTag, TextDiff};
use syntect::easy::HighlightLines;
use syntect::highlighting::{Style, Theme, ThemeSet};
use syntect::parsing::SyntaxSet;
use syntect::util::LinesWithEndings;

/// The syntect theme used for every highlight.
///
/// One of the two dark themes syntect's own dump ships. The pane is dark, and
/// picking here rather than in QML keeps a single palette: the colours are
/// inline on each span, so the pane never has to know the theme's name.
const THEME_NAME: &str = "base16-eighties.dark";

/// One fenced code block found in an assistant message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodeBlock {
    /// The fence's language tag, `None` when the fence carried none.
    pub language: Option<String>,
    /// The code exactly as the model wrote it, newline-terminated.
    pub source: String,
}

/// The syntax and theme dumps, parsed once.
///
/// Loading them costs milliseconds and allocates a few megabytes, and a turn
/// can settle many blocks, so this is built on the first render and shared
/// after that.
struct Highlighter {
    syntaxes: SyntaxSet,
    theme: Theme,
}

/// The process-wide [`Highlighter`].
static HIGHLIGHTER: OnceLock<Highlighter> = OnceLock::new();

/// Borrow the shared highlighter, building it on first use.
fn highlighter() -> &'static Highlighter {
    HIGHLIGHTER.get_or_init(|| {
        let mut themes = ThemeSet::load_defaults();
        let theme = themes.themes.remove(THEME_NAME).unwrap_or_default();
        Highlighter {
            syntaxes: SyntaxSet::load_defaults_newlines(),
            theme,
        }
    })
}

/// Every fenced code block in one settled assistant message, in order.
///
/// This runs over the text a `content_block_stop` settled, which is why it
/// takes a whole message rather than a delta: a fence split across two
/// deltas is not a fence yet.
///
/// An unterminated fence is not an error. `pulldown-cmark` closes it at the
/// end of the input, so the block comes back with whatever the model had
/// written so far, which is the same thing the pane would show.
#[must_use]
pub fn code_blocks(markdown: &str) -> Vec<CodeBlock> {
    let mut blocks = Vec::new();
    let mut open: Option<CodeBlock> = None;
    for event in Parser::new_ext(markdown, Options::all()) {
        match event {
            Event::Start(Tag::CodeBlock(kind)) => {
                open = Some(CodeBlock {
                    language: fence_language(&kind),
                    source: String::new(),
                });
            }
            Event::Text(text) => {
                if let Some(block) = open.as_mut() {
                    block.source.push_str(&text);
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some(block) = open.take() {
                    blocks.push(block);
                }
            }
            _ => {}
        }
    }
    // A fence the model never closed still produced its Start and its Text.
    // pulldown-cmark does emit the End for it, so this is belt and braces
    // against a parser that stops mid-stream rather than a path the current
    // one takes.
    blocks.extend(open);
    blocks
}

/// The language tag on a fence, `None` for an indented block or a bare fence.
fn fence_language(kind: &CodeBlockKind<'_>) -> Option<String> {
    let CodeBlockKind::Fenced(info) = kind else {
        return None;
    };
    // The info string is everything after the backticks. Only the first word
    // names a language; the rest is attributes the pane has no use for.
    info.split_whitespace().next().map(str::to_owned)
}

/// Highlight one code block into the rich-text subset a QML `Text` draws.
///
/// A language syntect has no syntax for degrades to plain escaped text
/// rather than failing, because a model naming a language nobody has heard
/// of is normal and is not a reason to drop the block.
#[must_use]
pub fn code_block_html(source: &str, language: Option<&str>) -> String {
    let Highlighter { syntaxes, theme } = highlighter();
    let syntax = language
        .and_then(|name| {
            syntaxes
                .find_syntax_by_token(name)
                .or_else(|| syntaxes.find_syntax_by_extension(name))
        })
        .unwrap_or_else(|| syntaxes.find_syntax_plain_text());

    let mut html = String::from("<pre class=\"code\">");
    let mut lines = HighlightLines::new(syntax, theme);
    for line in LinesWithEndings::from(source) {
        // A syntax that fails mid-line is not a reason to drop the block, so
        // the line goes out unstyled and the rest keeps its colours.
        match lines.highlight_line(line, syntaxes) {
            Ok(spans) => push_spans(&mut html, &spans),
            Err(err) => {
                tracing::debug!(error = %err, "highlighting a line failed; emitting it plain");
                escape_into(&mut html, line);
            }
        }
    }
    html.push_str("</pre>");
    html
}

/// Write one line's highlighted spans, escaping every byte of the source.
fn push_spans(html: &mut String, spans: &[(Style, &str)]) {
    for (style, text) in spans {
        let colour = style.foreground;
        // The colour comes from the theme, never from the model, so it is
        // the one thing in this function that does not need escaping. The
        // text always does.
        let _ = write!(
            html,
            "<span style=\"color:#{:02x}{:02x}{:02x}\">",
            colour.r, colour.g, colour.b
        );
        escape_into(html, text);
        html.push_str("</span>");
    }
}

/// Render a file change as the rich-text subset a QML `Text` draws.
///
/// Line-oriented rather than word-oriented, because a QML `Text` has no way
/// to show an intra-line highlight that a person can read at pane width.
#[must_use]
pub fn diff_html(old_text: &str, new_text: &str) -> String {
    let mut html = String::from("<pre class=\"diff\">");
    for change in TextDiff::from_lines(old_text, new_text).iter_all_changes() {
        let (class, marker) = match change.tag() {
            ChangeTag::Delete => ("del", '-'),
            ChangeTag::Insert => ("ins", '+'),
            ChangeTag::Equal => ("ctx", ' '),
        };
        let _ = write!(html, "<span class=\"{class}\">{marker}");
        escape_into(&mut html, change.value());
        html.push_str("</span>");
    }
    html.push_str("</pre>");
    html
}

/// How many lines a change added and how many it removed.
///
/// This is what `diff.added` and `diff.removed` carry, and it is derived
/// from the same diff [`diff_html`] renders so the numbers and the picture
/// can never disagree.
#[must_use]
pub fn diff_line_counts(old_text: &str, new_text: &str) -> (u32, u32) {
    let mut added = 0_u32;
    let mut removed = 0_u32;
    for change in TextDiff::from_lines(old_text, new_text).iter_all_changes() {
        match change.tag() {
            ChangeTag::Insert => added = added.saturating_add(1),
            ChangeTag::Delete => removed = removed.saturating_add(1),
            ChangeTag::Equal => {}
        }
    }
    (added, removed)
}

/// Escape one model-derived string for the rich-text subset.
///
/// Five characters, which is the whole set Qt's rich text parser treats as
/// markup. Nothing else in this module writes model output into the result,
/// so this is the single gate between what a model wrote and what the pane
/// draws.
#[must_use]
pub fn escape_text(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    escape_into(&mut escaped, text);
    escaped
}

/// [`escape_text`] into a buffer that already exists.
fn escape_into(out: &mut String, text: &str) {
    for ch in text.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            other => out.push(other),
        }
    }
}
