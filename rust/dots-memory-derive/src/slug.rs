//! Map arbitrary text to a Mermaid-safe node id.
//!
//! Mirrors the contract `rust/pg-agentmem/src/mermaid.rs` enforces on
//! parse (design spec section 8): `[A-Za-z0-9_]+`, never a bare reserved
//! word. One rule that module's own `slug_v1` does not need to carry,
//! because it slugifies free-form entity names rather than repo-relative
//! paths and app names that never start with a digit in practice, is
//! enforced here too: a leading digit is invalid to
//! `mermaid::parse_ident`, which only accepts `[A-Za-z_]` as a first
//! character.

/// Identifiers Mermaid's grammar reserves for statement keywords, copied
/// from `rust/pg-agentmem/src/mermaid.rs::RESERVED_WORDS` rather than
/// imported from it: that crate builds through pgrx against real
/// `PostgreSQL` headers, and this one is a plain checkout walker with no
/// server to link against.
const RESERVED_WORDS: &[&str] = &[
    "call",
    "class",
    "classDef",
    "end",
    "flowchart",
    "graph",
    "href",
    "linkStyle",
    "style",
    "subgraph",
    "click",
];

/// Slugify `input` into `[A-Za-z0-9_]+`: never empty, never leading with
/// a digit, never a bare reserved word. `/` and `.` fold in with every
/// other non-identifier character, so a repo-relative path such as
/// `nix/modules/searxng.nix` becomes one flat id.
#[must_use]
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
    if out.starts_with(|c: char| c.is_ascii_digit()) {
        out.insert(0, '_');
    }
    if RESERVED_WORDS.contains(&out.as_str()) {
        out.push('_');
    }
    out
}
