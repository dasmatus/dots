//! Library surface for `dots-memory-derive`: reads this checkout's own
//! structure -- never a model, never judgement -- and emits it as
//! `origin = 'derived'` Mermaid edges, per
//! `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`
//! section 7 and plan 5, task 2.

pub mod apps;
pub mod dots_pairs;
pub mod edge;
pub mod home_imports;
pub mod nixos_modules;
pub mod slug;
mod util;

use std::collections::HashSet;
use std::path::Path;

/// Walk `repo_root` and render one `flowchart TD` document covering every
/// source in plan 5 task 2: the `modules` list in `flake/nixos.nix`, the
/// `imports` list in `nix/home/default.nix`, `dots.*`
/// declaration-to-use pairs, and the app names in `flake/apps.nix`.
///
/// # Errors
/// Returns `Err` if any of the four sources cannot be read or parsed.
pub fn emit(repo_root: &Path) -> Result<String, String> {
    let mut edges = Vec::new();
    edges.extend(nixos_modules::extract(repo_root)?);
    edges.extend(home_imports::extract(repo_root)?);
    edges.extend(dots_pairs::extract(repo_root)?);
    edges.extend(apps::extract(repo_root)?);

    let mut seen = HashSet::new();
    edges.retain(|e| seen.insert(e.clone()));

    Ok(edge::render(&edges))
}
