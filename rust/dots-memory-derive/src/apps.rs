//! Extracts one `defines` edge per app name in `flake/apps.nix`'s output
//! attrset -- the `nix run .#<name>` surface.

use std::path::Path;

use regex::Regex;

use crate::edge::Edge;
use crate::slug::slug;

/// Root node id for `flake/apps.nix` itself.
const ANCHOR: &str = "flake_apps_nix";

/// Read `flake/apps.nix` under `repo_root` and emit one `defines` edge
/// per top-level `<name> = mk...` entry.
///
/// # Errors
/// Returns `Err` if the file cannot be read or the app-name regex fails
/// to compile.
pub fn extract(repo_root: &Path) -> Result<Vec<Edge>, String> {
    let file = repo_root.join("flake/apps.nix");
    let text = std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    let re = Regex::new(r"(?m)^\s*([A-Za-z][A-Za-z0-9-]*)\s*=\s*mk").map_err(|e| e.to_string())?;

    Ok(re
        .captures_iter(&text)
        .map(|c| Edge {
            src: ANCHOR.to_string(),
            verb: "defines".to_string(),
            dst: slug(&c[1]),
        })
        .collect())
}
