//! End-to-end: run the extractor against this checkout's own repo root
//! and check the two invariants plan 5 task 2 asks for -- `searxng.nix`
//! shows up as imported by `flake/nixos.nix`, and every emitted id is a
//! Mermaid-safe identifier.

use std::path::{Path, PathBuf};

use dots_memory_derive::emit;

/// `CARGO_MANIFEST_DIR` is `<repo>/rust/dots-memory-derive`; the repo
/// root this crate reads sits two levels up.
fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("rust/dots-memory-derive sits two levels under the repo root")
        .to_path_buf()
}

/// One parsed `src [-->|"verb"|] dst` line, mirroring the two link forms
/// `edge::render` ever emits -- not a general Mermaid parser, just the
/// inverse of this crate's own fixed output format.
struct ParsedEdge {
    src: String,
    verb: String,
    dst: String,
}

fn parse_edges(doc: &str) -> Vec<ParsedEdge> {
    doc.lines()
        .filter_map(|line| {
            let line = line.trim();
            if let Some((src, rest)) = line.split_once("-->|\"") {
                let (verb, dst) = rest.split_once("\"| ")?;
                Some(ParsedEdge {
                    src: src.trim().to_string(),
                    verb: verb.to_string(),
                    dst: dst.trim().to_string(),
                })
            } else if let Some((src, dst)) = line.split_once("-->") {
                Some(ParsedEdge {
                    src: src.trim().to_string(),
                    verb: String::new(),
                    dst: dst.trim().to_string(),
                })
            } else {
                None
            }
        })
        .collect()
}

fn is_mermaid_safe_id(id: &str) -> bool {
    !id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[test]
fn names_searxng_nix_as_imported_by_flake_nixos() {
    let doc = emit(&repo_root()).expect("extraction against the real repo checkout must succeed");
    let edges = parse_edges(&doc);

    let found = edges.iter().any(|e| {
        e.src == "flake_nixos_nix" && e.verb == "imports" && e.dst == "nix_modules_searxng_nix"
    });
    assert!(
        found,
        "expected an `imports` edge from flake_nixos_nix to nix_modules_searxng_nix, got:\n{doc}"
    );
}

#[test]
fn every_id_is_mermaid_safe() {
    let doc = emit(&repo_root()).expect("extraction against the real repo checkout must succeed");
    let edges = parse_edges(&doc);
    assert!(!edges.is_empty(), "expected at least one edge, got:\n{doc}");

    for e in &edges {
        assert!(
            is_mermaid_safe_id(&e.src),
            "src `{}` is not [A-Za-z0-9_]+",
            e.src
        );
        assert!(
            is_mermaid_safe_id(&e.dst),
            "dst `{}` is not [A-Za-z0-9_]+",
            e.dst
        );
    }
}
