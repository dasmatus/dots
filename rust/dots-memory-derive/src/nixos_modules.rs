//! Extracts one `imports` edge per literal `.nix` path in
//! `flake/nixos.nix`'s `modules` list -- the declarative module set every
//! installed system and both `LiveISO` variants are assembled from.

use std::path::Path;

use crate::edge::Edge;
use crate::slug::slug;
use crate::util::block_between;

/// Root node id for `flake/nixos.nix` itself.
const ANCHOR: &str = "flake_nixos_nix";

/// One line inside the `modules = [ ... ];` list, if it is a bare path
/// literal like `../nix/modules/services/searxng.nix` rather than an `inputs.*`
/// reference or a function call like `(import ../nix/system/disko.nix { ... })`.
fn parse_module_line(line: &str) -> Option<&str> {
    let line = line.trim();
    let is_bare_path = line.starts_with("../")
        && Path::new(line)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("nix"))
        && !line.contains(['(', ' ']);
    is_bare_path.then_some(line)
}

/// Read `flake/nixos.nix` under `repo_root` and emit one `imports` edge
/// per bare path in its `modules` list.
///
/// # Errors
/// Returns `Err` if the file cannot be read or has no `modules = [ ... ];`
/// list.
pub fn extract(repo_root: &Path) -> Result<Vec<Edge>, String> {
    let file = repo_root.join("flake/nixos.nix");
    let text = std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    let block = block_between(&text, "modules = [", "];")
        .ok_or_else(|| format!("{}: no `modules = [ ... ];` list found", file.display()))?;

    Ok(block
        .lines()
        .filter_map(parse_module_line)
        .map(|raw| {
            // `../nix/modules/services/searxng.nix`, relative to `flake/` -- one
            // `../` strips straight to the repo-root-relative path since
            // `flake/` sits directly under the root.
            let rel = raw.strip_prefix("../").unwrap_or(raw);
            Edge {
                src: ANCHOR.to_string(),
                verb: "imports".to_string(),
                dst: slug(rel),
            }
        })
        .collect())
}
