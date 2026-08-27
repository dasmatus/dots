//! Slugification and Mermaid-flowchart rendering: the inverse direction of
//! `mermaid.rs`.
use std::fmt::Write as _;

use crate::mermaid::RESERVED_WORDS;

/// Map arbitrary text to a Mermaid-safe identifier: `[A-Za-z0-9_]+`, never
/// empty, never a bare reserved word. Backs `agentmem.slug_v1` (see
/// `lib.rs`).
pub fn slug(input: &str) -> String {
    let mut out: String = input
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if out.is_empty() {
        out.push('_');
    }
    if RESERVED_WORDS.contains(&out.as_str()) {
        out.push('_');
    }
    out
}

/// Escape a label for Mermaid's `#entity;` syntax. `#` is escaped first:
/// the escapes for `"` and `|` introduce fresh `#` characters, and escaping
/// `#` afterwards would double-escape them.
fn escape_label(label: &str) -> String {
    label
        .replace('#', "#35;")
        .replace('"', "#quot;")
        .replace('|', "#124;")
}

/// Render parallel `src`/`verb`/`dst` arrays as a flowchart document. Backs
/// `agentmem.edges_to_mermaid` (see `lib.rs`). Every id is slugified; every
/// non-empty verb becomes a quoted, entity-escaped pipe label. There is no
/// directedness input, so every edge renders with the same directed arrow.
pub fn render(src: &[String], verb: &[String], dst: &[String]) -> String {
    if src.len() != verb.len() || src.len() != dst.len() {
        pgrx::error!(
            "edges_to_mermaid: src, verb and dst must have the same length (got {}, {}, {})",
            src.len(),
            verb.len(),
            dst.len()
        );
    }
    let mut out = String::from("flowchart LR\n");
    for ((s, v), d) in src.iter().zip(verb.iter()).zip(dst.iter()) {
        let s = slug(s);
        let d = slug(d);
        if v.is_empty() {
            let _ = writeln!(out, "    {s} --> {d}");
        } else {
            let label = escape_label(v);
            let _ = writeln!(out, "    {s} -->|\"{label}\"| {d}");
        }
    }
    out
}
