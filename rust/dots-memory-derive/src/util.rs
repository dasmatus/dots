//! Small text-slicing helpers shared by the extractors. None of this is a
//! Nix parser: every source file this crate reads follows one consistent,
//! already-formatted layout (`nixpkgs-fmt`/`nixfmt` output), so a
//! substring scan is enough and a real grammar would be overkill for a
//! mechanical extractor that gets rebuilt at every commit anyway.

use std::path::{Path, PathBuf};

/// The substring strictly between the first `open` and the following
/// `close`, e.g. the body of a `modules = [ ... ];` list. Good enough
/// wherever `close` cannot occur, unmatched, before the list actually
/// ends -- true for every literal list this crate reads, none of which
/// contain a nested `]`.
pub fn block_between<'a>(text: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let start = text.find(open)? + open.len();
    let rel_end = text[start..].find(close)?;
    Some(&text[start..start + rel_end])
}

/// The substring from the first `{` following `needle` through its
/// balanced matching `}`, inclusive. Nested Nix attrsets are not a
/// regular language, so this is a hand-rolled bracket count rather than
/// a single regex -- used only for `options.dots = { ... }`, the one
/// block this crate needs to walk by nesting rather than by line.
pub fn balanced_block<'a>(text: &'a str, needle: &str) -> Option<&'a str> {
    let after = text.find(needle)? + needle.len();
    let open = after + text[after..].find('{')?;
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    for (i, &b) in bytes.iter().enumerate().skip(open) {
        match b {
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[open..=i]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Every `.nix` file under `dir`, walked recursively.
pub fn collect_nix_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    if !dir.is_dir() {
        return Ok(());
    }
    let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if path.is_dir() {
            collect_nix_files(&path, out)?;
        } else if path.extension().is_some_and(|e| e == "nix") {
            out.push(path);
        }
    }
    Ok(())
}

/// `file`, relative to `root`, with forward slashes -- the form every
/// extracted id is slugified from.
pub fn rel_path(root: &Path, file: &Path) -> String {
    file.strip_prefix(root)
        .unwrap_or(file)
        .to_string_lossy()
        .replace('\\', "/")
}

fn is_ident_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_ident_or_dot_byte(b: u8) -> bool {
    is_ident_byte(b) || b == b'.'
}

/// Whether `needle` occurs in `text` as a whole dotted token: not
/// preceded by an identifier character, and not followed by one or by a
/// `.` that would make it a prefix of a longer path.
pub fn contains_token(text: &str, needle: &str) -> bool {
    let bytes = text.as_bytes();
    let mut start = 0;
    while let Some(pos) = text.get(start..).and_then(|t| t.find(needle)) {
        let idx = start + pos;
        let before_ok = idx == 0 || !is_ident_byte(bytes[idx - 1]);
        let after_idx = idx + needle.len();
        let after_ok = after_idx >= bytes.len() || !is_ident_or_dot_byte(bytes[after_idx]);
        if before_ok && after_ok {
            return true;
        }
        start = idx + 1;
    }
    false
}

/// `text` with every comment line (trimmed start `#`) blanked out, so a
/// prose mention of a `dots.*` path in a comment is never mistaken for a
/// genuine use.
pub fn strip_comment_lines(text: &str) -> String {
    text.lines()
        .map(|l| {
            if l.trim_start().starts_with('#') {
                ""
            } else {
                l
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}
