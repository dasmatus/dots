//! One derived-origin edge, and the strict-subset Mermaid rendering that
//! turns a list of them back into a document
//! `agentmem.mermaid_edges` (`rust/pg-agentmem/src/mermaid.rs`) accepts.

use std::fmt::Write as _;

/// One edge. `src` and `dst` are already slug-safe ids (see `slug.rs`);
/// `verb` is free text, entity-escaped on render.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Edge {
    pub src: String,
    pub verb: String,
    pub dst: String,
}

/// Escape a label for Mermaid's `#entity;` syntax -- `#` first, so the
/// escapes for `"` and `|` do not introduce fresh `#` characters that
/// would otherwise get double-escaped. Mirrors
/// `rust/pg-agentmem/src/render.rs::escape_label`, duplicated rather than
/// imported for the same reason `slug.rs` duplicates `RESERVED_WORDS`.
fn escape_label(label: &str) -> String {
    label
        .replace('#', "#35;")
        .replace('"', "#quot;")
        .replace('|', "#124;")
}

/// Render edges as a `flowchart TD` document: a bare arrow for an empty
/// verb, a quoted pipe label otherwise -- the two link forms
/// `rust/pg-agentmem/src/mermaid.rs::parse_link` accepts without a
/// surrounded label.
#[must_use]
pub fn render(edges: &[Edge]) -> String {
    let mut out = String::from("flowchart TD\n");
    for e in edges {
        if e.verb.is_empty() {
            let _ = writeln!(out, "    {} --> {}", e.src, e.dst);
        } else {
            let _ = writeln!(
                out,
                "    {} -->|\"{}\"| {}",
                e.src,
                escape_label(&e.verb),
                e.dst
            );
        }
    }
    out
}
