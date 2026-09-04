//! Extracts one edge per `dots.*` NixOS option consumed outside the file
//! that declares it: direct `options.dots.<path> = ...` declarations
//! (`nix/modules/{steam,desktop,form-factor}.nix`), plus the nested
//! `options.dots = { ... }` block in `nix/modules/dots.nix`, each matched
//! against every other `.nix` file under `nix/` and `flake/` that
//! mentions `dots.<path>`.
//!
//! A mechanical extractor, not a Nix evaluator: nesting inside the big
//! block is read off consistent 2-space indentation (`nixfmt` output)
//! rather than parsed from the grammar, and a "use" is any textual
//! occurrence outside the declaring file. Good enough for a structural
//! signal that gets rebuilt at every commit -- nothing here is asserted
//! as a fact a human could not re-derive by grepping.

use std::path::Path;

use regex::Regex;

use crate::edge::Edge;
use crate::slug::slug;
use crate::util::{
    balanced_block, collect_nix_files, contains_token, rel_path, strip_comment_lines,
};

/// One `dots.<path>` declaration and the repo-root-relative file it came
/// from.
struct Declared {
    path: String,
    file: String,
}

/// Direct `options.dots.<path> = ...` declarations in `text`, skipping
/// comment lines so a prose mention (`nix/home/ai/claude.nix` explains its
/// own gate this way) is never mistaken for the real declaration.
fn direct_declarations(text: &str, rel: &str) -> Vec<Declared> {
    let re = Regex::new(r"^\s*options\.dots\.([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)\s*=").unwrap();
    text.lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .filter_map(|l| re.captures(l))
        .map(|c| Declared {
            path: c[1].to_string(),
            file: rel.to_string(),
        })
        .collect()
}

/// Walk an `options.dots = { ... }` block (already sliced to its
/// balanced braces) by indentation, returning one dotted path per
/// `mkOption` leaf it finds. `stack` holds `(indent_columns, namespace)`
/// frames from the nested attrsets a leaf sits under.
fn nested_declarations(block: &str) -> Vec<String> {
    let open_ns = Regex::new(r"^(\s*)([A-Za-z][A-Za-z0-9_]*)\s*=\s*\{\s*$").unwrap();
    let leaf = Regex::new(r"^(\s*)([A-Za-z][A-Za-z0-9_]*)\s*=\s*(?:lib\.)?mkOption\s*\{").unwrap();
    let close = Regex::new(r"^(\s*)\};\s*$").unwrap();

    let mut stack: Vec<(usize, String)> = Vec::new();
    let mut paths = Vec::new();

    for line in block.lines() {
        if let Some(c) = leaf.captures(line) {
            let indent = c[1].len();
            while stack.last().is_some_and(|(i, _)| *i >= indent) {
                stack.pop();
            }
            let mut segments: Vec<&str> = stack.iter().map(|(_, n)| n.as_str()).collect();
            segments.push(&c[2]);
            paths.push(segments.join("."));
        } else if let Some(c) = open_ns.captures(line) {
            let indent = c[1].len();
            while stack.last().is_some_and(|(i, _)| *i >= indent) {
                stack.pop();
            }
            stack.push((indent, c[2].to_string()));
        } else if let Some(c) = close.captures(line) {
            let indent = c[1].len();
            if stack.last().is_some_and(|(i, _)| *i == indent) {
                stack.pop();
            }
        }
    }
    paths
}

/// Every `.nix` file under `nix/` and `flake/`, as repo-root-relative
/// paths alongside their contents.
fn read_nix_tree(repo_root: &Path) -> Result<Vec<(String, String)>, String> {
    let mut files = Vec::new();
    collect_nix_files(&repo_root.join("nix"), &mut files)?;
    collect_nix_files(&repo_root.join("flake"), &mut files)?;

    files
        .into_iter()
        .map(|path| {
            let text =
                std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            Ok((rel_path(repo_root, &path), text))
        })
        .collect()
}

/// Read every `.nix` file under `nix/` and `flake/`, find every declared
/// `dots.*` option, and emit one edge per file (other than the declaring
/// one) that mentions it.
///
/// # Errors
/// Returns `Err` if any `.nix` file under `nix/` or `flake/` cannot be
/// read.
pub fn extract(repo_root: &Path) -> Result<Vec<Edge>, String> {
    let tree = read_nix_tree(repo_root)?;

    let mut declared: Vec<Declared> = Vec::new();
    for (rel, text) in &tree {
        declared.extend(direct_declarations(text, rel));
        if let Some(block) = balanced_block(text, "options.dots = ") {
            declared.extend(nested_declarations(block).into_iter().map(|path| Declared {
                path,
                file: rel.clone(),
            }));
        }
    }

    let mut edges = Vec::new();
    for d in &declared {
        let needle = format!("dots.{}", d.path);
        for (rel, text) in &tree {
            if *rel == d.file {
                continue;
            }
            if contains_token(&strip_comment_lines(text), &needle) {
                edges.push(Edge {
                    src: slug(&d.file),
                    verb: needle.clone(),
                    dst: slug(rel),
                });
            }
        }
    }
    Ok(edges)
}
