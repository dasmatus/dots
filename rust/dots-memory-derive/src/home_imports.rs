//! Extracts one `imports` edge per literal path in `nix/home/default.nix`'s
//! `imports` list -- every Home Manager module the profile assembles from.

use std::path::Path;

use crate::edge::Edge;
use crate::slug::slug;
use crate::util::block_between;

/// Root node id for `nix/home/default.nix` itself.
const ANCHOR: &str = "nix_home_default_nix";

/// One line inside the `imports = [ ... ];` list, if it is a bare
/// relative path like `./kitty.nix` or `./quickshell` rather than
/// anything more involved.
fn parse_import_line(line: &str) -> Option<&str> {
    let line = line.trim();
    let is_bare_path = line.starts_with("./") && !line.contains(['(', ' ']);
    is_bare_path.then_some(line)
}

/// Read `nix/home/default.nix` under `repo_root` and emit one `imports`
/// edge per bare path in its `imports` list.
///
/// # Errors
/// Returns `Err` if the file cannot be read or has no `imports = [ ... ];`
/// list.
pub fn extract(repo_root: &Path) -> Result<Vec<Edge>, String> {
    let file = repo_root.join("nix/home/default.nix");
    let text = std::fs::read_to_string(&file).map_err(|e| format!("{}: {e}", file.display()))?;
    let block = block_between(&text, "imports = [", "];")
        .ok_or_else(|| format!("{}: no `imports = [ ... ];` list found", file.display()))?;

    Ok(block
        .lines()
        .filter_map(parse_import_line)
        .map(|raw| {
            // `./kitty.nix` (or an extensionless module dir like
            // `./quickshell`), relative to `nix/home/`.
            let rel = raw.strip_prefix("./").unwrap_or(raw);
            let rel = format!("nix/home/{rel}");
            Edge {
                src: ANCHOR.to_string(),
                verb: "imports".to_string(),
                dst: slug(&rel),
            }
        })
        .collect())
}
