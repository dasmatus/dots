//! `catalog --json`: the permissions-page catalog the Settings sandbox
//! page reads instead of `policy dump`'s `apps` map directly.
//!
//! Split the same way `report.rs` is: a pure half ([`parse_desktop_entry`],
//! [`build_catalog`]) that only ever sees already-read text and an
//! already-resolved [`policy::ResolvedPolicySet`], and a thin impure half
//! ([`scan`] and its helpers) that walks `$XDG_DATA_HOME`/`$XDG_DATA_DIRS`
//! and reads real files. Only the pure half is exercised by
//! `tests/catalog.rs`, against fixtures under `tests/fixtures/`, per the
//! same reasoning `report.rs` documents: a desktop-entry parser is small
//! enough to hand-roll, and its edge cases (group boundaries, localised
//! keys, a stray capability name) are exactly what a fixture-driven test
//! can pin down without a real XDG tree.
//!
//! Every discovered `.desktop` file contributes only `name`, `icon` and
//! its own `X-Dots-Sandbox-Tier`/`-Caps`/`-Paths` declaration — the
//! vocabulary `wrapSandboxed` actually built the wrapper against — plus
//! the file's own path as `source`. `state` (what each of those
//! capabilities currently resolves to, defaults layered with overrides)
//! always comes from the resolved policy the caller already had to
//! compute for `policy dump`, never from the file, so a user override
//! shows up here without touching a single desktop entry. An app the
//! defaults catalog defines but no installed package ever wrapped — the
//! flake apps run via `nix run .#foo`, which have no `share/applications`
//! entry at all — still gets a [`CatalogEntry`], built from the resolved
//! policy alone, with `source: null`: it must not vanish from the
//! permissions page just because nothing points a desktop launcher at it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::policy::{Capability, PathMode, PolicyState, ResolvedApp, ResolvedPolicySet, Tier};

/// The catalog document's own schema version, independent of
/// [`policy::SUPPORTED_VERSION`](crate::policy::SUPPORTED_VERSION) — this
/// is the shape `catalog --json` prints, not the shape a policy file is
/// written in.
pub const CATALOG_VERSION: u32 = 1;

/// One `path:mode` pair, either declared in a desktop entry's
/// `X-Dots-Sandbox-Paths` or carried over from a resolved policy grant
/// that has no desktop entry to have declared it in the first place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CatalogPathEntry {
    pub path: String,
    pub mode: PathMode,
}

/// One app as `catalog --json` emits it: desktop metadata (when a
/// desktop entry was found) merged with the app's resolved policy state
/// (always present, whether or not a desktop entry was).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CatalogEntry {
    #[serde(rename = "appId")]
    pub app_id: String,
    pub name: Option<String>,
    pub icon: Option<String>,
    pub tier: Option<Tier>,
    pub caps: Vec<String>,
    pub paths: Vec<CatalogPathEntry>,
    pub source: Option<String>,
    pub state: BTreeMap<String, PolicyState>,
}

/// The full document `catalog --json` prints.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Catalog {
    pub version: u32,
    pub apps: Vec<CatalogEntry>,
}

/// One desktop entry's sandbox-relevant fields, parsed but not yet
/// merged with a resolved policy or attached to the file it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DesktopSandboxEntry {
    app_id: String,
    name: Option<String>,
    icon: Option<String>,
    tier: Option<Tier>,
    caps: Vec<Capability>,
    paths: Vec<CatalogPathEntry>,
}

/// Collects the `[Desktop Entry]` group's unlocalised `key=value` pairs
/// out of a whole `.desktop` file, per the freedesktop desktop-entry INI
/// dialect: `[Group Name]` headers switch the current group, blank lines
/// and `#`-prefixed comments are skipped, values are never quoted, and a
/// localised key (`Name[de]=`) is a different key from its unlocalised
/// form — this scanner only ever wants the latter.
///
/// Every other group — most importantly `[Desktop Action foo]`, which
/// carries its own `Name=`/`Icon=`/`Exec=` for the action's own menu
/// entry — is walked over without contributing anything, so an action's
/// `Name=` can never shadow the application's own. Returns `None` only
/// when the file never opens a `[Desktop Entry]` group at all.
fn desktop_entry_group(contents: &str) -> Option<BTreeMap<String, String>> {
    let mut current_group: Option<String> = None;
    let mut entry: Option<BTreeMap<String, String>> = None;

    for raw_line in contents.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(header) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            current_group = Some(header.to_string());
            if header == "Desktop Entry" {
                entry.get_or_insert_with(BTreeMap::new);
            }
            continue;
        }
        if current_group.as_deref() != Some("Desktop Entry") {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.contains('[') {
            // A localised key, e.g. `Name[de]=`: legal freedesktop syntax,
            // but this scanner only ever wants the unlocalised `Name`.
            continue;
        }
        if let Some(map) = entry.as_mut() {
            map.insert(key.to_string(), value.trim().to_string());
        }
    }
    entry
}

/// Parses `X-Dots-Sandbox-Caps`' semicolon-separated capability list
/// (trailing `;` per freedesktop list convention). A name
/// [`Capability::parse`] does not recognise is dropped with a warning
/// rather than failing the whole entry — `wrap.nix` already refuses to
/// build a desktop file with a typo'd capability name (see the contract
/// this module implements), so a name this binary cannot parse here can
/// only mean a foreign or hand-edited file, and one bad name in it must
/// not hide the rest of a real app's entry.
fn parse_declared_caps(app_id: &str, raw: &str) -> Vec<Capability> {
    raw.split(';')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|name| {
            let parsed = Capability::parse(name);
            if parsed.is_none() {
                tracing::warn!(
                    app_id,
                    capability = name,
                    "ignoring unparseable capability name in desktop entry"
                );
            }
            parsed
        })
        .collect()
}

fn parse_tier(value: &str) -> Option<Tier> {
    match value {
        "vm" => Some(Tier::Vm),
        "container" => Some(Tier::Container),
        _ => None,
    }
}

fn parse_path_mode(value: &str) -> Option<PathMode> {
    match value {
        "rw" => Some(PathMode::Rw),
        "ro" => Some(PathMode::Ro),
        _ => None,
    }
}

/// Parses `X-Dots-Sandbox-Paths`' semicolon-separated `path:mode` pairs.
/// Split from the right on `:` — a mode is always the last, fixed-width
/// segment, while an (unusual but valid) path could itself contain a
/// colon — and any pair that does not split cleanly, or whose mode is
/// not `rw`/`ro`, is dropped with a warning rather than failing the
/// whole entry, the same policy [`parse_declared_caps`] follows.
fn parse_declared_paths(app_id: &str, raw: &str) -> Vec<CatalogPathEntry> {
    raw.split(';')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|pair| {
            let Some((path, mode)) = pair.rsplit_once(':') else {
                tracing::warn!(
                    app_id,
                    pair,
                    "ignoring malformed X-Dots-Sandbox-Paths entry (expected path:mode)"
                );
                return None;
            };
            let Some(mode) = parse_path_mode(mode.trim()) else {
                tracing::warn!(app_id, pair, "ignoring path entry with unknown mode");
                return None;
            };
            Some(CatalogPathEntry {
                path: path.trim().to_string(),
                mode,
            })
        })
        .collect()
}

/// Parses one `.desktop` file's contents into its sandbox-relevant
/// fields. Returns `None` when the `[Desktop Entry]` group carries no
/// `X-Dots-Sandbox-AppId` — the common case, since most installed
/// desktop files are not wrapped apps at all, and exactly the case that
/// must leave the file out of the catalog rather than erroring.
fn parse_desktop_entry(contents: &str) -> Option<DesktopSandboxEntry> {
    let group = desktop_entry_group(contents)?;
    let app_id = group.get("X-Dots-Sandbox-AppId")?.clone();
    let tier = group.get("X-Dots-Sandbox-Tier").and_then(|v| parse_tier(v));
    let caps = group
        .get("X-Dots-Sandbox-Caps")
        .map(|raw| parse_declared_caps(&app_id, raw))
        .unwrap_or_default();
    let paths = group
        .get("X-Dots-Sandbox-Paths")
        .map(|raw| parse_declared_paths(&app_id, raw))
        .unwrap_or_default();
    Some(DesktopSandboxEntry {
        app_id,
        name: group.get("Name").cloned(),
        icon: group.get("Icon").cloned(),
        tier,
        caps,
        paths,
    })
}

/// Builds a [`CatalogEntry`] for an app a desktop entry was found for:
/// desktop metadata plus whatever the resolved policy currently says
/// about each capability the entry declares.
fn entry_from_discovered(
    discovered: &DesktopSandboxEntry,
    source: &Path,
    resolved: Option<&ResolvedApp>,
) -> CatalogEntry {
    CatalogEntry {
        app_id: discovered.app_id.clone(),
        name: discovered.name.clone(),
        icon: discovered.icon.clone(),
        tier: discovered.tier,
        caps: discovered
            .caps
            .iter()
            .map(|cap| cap.as_str().to_string())
            .collect(),
        paths: discovered.paths.clone(),
        source: Some(source.display().to_string()),
        state: resolved_state(resolved),
    }
}

/// Builds a [`CatalogEntry`] for an app the defaults catalog defines but
/// no desktop entry was ever found for — the flake apps, run only via
/// `nix run .#foo`, never get a `share/applications` entry at all. Every
/// field this app has comes from the resolved policy alone; `source`
/// stays `None` rather than the app vanishing from the permissions page.
fn entry_from_policy_only(app_id: &str, resolved: Option<&ResolvedApp>) -> CatalogEntry {
    let (tier, caps, paths) = match resolved {
        Some(ResolvedApp::Sandboxed(policy)) => (
            Some(policy.tier),
            policy
                .capabilities
                .keys()
                .map(|cap| cap.as_str().to_string())
                .collect(),
            policy
                .paths
                .iter()
                .map(|grant| CatalogPathEntry {
                    path: grant.path.display().to_string(),
                    mode: grant.mode,
                })
                .collect(),
        ),
        Some(ResolvedApp::Unconfined { .. }) | None => (None, Vec::new(), Vec::new()),
    };
    CatalogEntry {
        app_id: app_id.to_string(),
        name: None,
        icon: None,
        tier,
        caps,
        paths,
        source: None,
        state: resolved_state(resolved),
    }
}

/// The per-capability resolved state every entry carries regardless of
/// where its other fields came from, so the Settings page needs exactly
/// one call to know both an app's declared capabilities and their
/// current allow/deny/ask state.
fn resolved_state(resolved: Option<&ResolvedApp>) -> BTreeMap<String, PolicyState> {
    match resolved {
        Some(ResolvedApp::Sandboxed(policy)) => policy
            .capabilities
            .iter()
            .map(|(cap, state)| (cap.as_str().to_string(), *state))
            .collect(),
        Some(ResolvedApp::Unconfined { .. }) | None => BTreeMap::new(),
    }
}

/// Builds the full catalog from already-read desktop-file contents and
/// an already-resolved policy set. Touches neither the filesystem nor
/// the environment, which is what makes it exercisable from
/// `tests/catalog.rs` against fixtures without a real XDG tree.
///
/// `desktop_files` must already be in XDG precedence order —
/// `$XDG_DATA_HOME` first, then each `$XDG_DATA_DIRS` entry in turn, as
/// [`scan`] provides — since a later file for an `app_id` an earlier one
/// already claimed is dropped here (first wins, per the freedesktop
/// spec's own precedence rule), not the other way around.
#[must_use]
pub fn build_catalog(desktop_files: &[(PathBuf, String)], policy: &ResolvedPolicySet) -> Catalog {
    let mut discovered: BTreeMap<String, (DesktopSandboxEntry, PathBuf)> = BTreeMap::new();
    for (path, contents) in desktop_files {
        let Some(entry) = parse_desktop_entry(contents) else {
            continue;
        };
        discovered
            .entry(entry.app_id.clone())
            .or_insert_with(|| (entry, path.clone()));
    }

    let app_ids: BTreeSet<String> = policy
        .apps
        .keys()
        .cloned()
        .chain(discovered.keys().cloned())
        .collect();

    let apps = app_ids
        .into_iter()
        .map(|app_id| {
            let resolved = policy.apps.get(&app_id);
            discovered.get(&app_id).map_or_else(
                || entry_from_policy_only(&app_id, resolved),
                |(entry, source)| entry_from_discovered(entry, source, resolved),
            )
        })
        .collect();

    Catalog {
        version: CATALOG_VERSION,
        apps,
    }
}

/// Resolves the ordered list of `applications` directories to scan, in
/// XDG precedence order: `$XDG_DATA_HOME` (or its `~/.local/share`
/// fallback) first, then each `$XDG_DATA_DIRS` entry in the order it
/// lists them (or the spec's own default,
/// `/usr/local/share/:/usr/share/`, when unset).
fn xdg_applications_dirs(home: &Path) -> Vec<PathBuf> {
    let data_home =
        std::env::var_os("XDG_DATA_HOME").map_or_else(|| home.join(".local/share"), PathBuf::from);
    let data_dirs =
        std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share/:/usr/share/".into());

    std::iter::once(data_home)
        .chain(
            data_dirs
                .split(':')
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
        )
        .map(|dir| dir.join("applications"))
        .collect()
}

/// Reads every `.desktop` file directly under `dirs`, in order, as
/// `(path, contents)` pairs — the shape [`build_catalog`] takes. A
/// directory that does not exist, or a file that fails to read (removed
/// mid-scan, not valid UTF-8), is skipped rather than aborting the whole
/// scan: one broken `applications` directory must not hide every other
/// app's entry.
fn read_desktop_files(dirs: &[PathBuf]) -> Vec<(PathBuf, String)> {
    let mut files = Vec::new();
    for dir in dirs {
        let Ok(read_dir) = std::fs::read_dir(dir) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = read_dir
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "desktop"))
            .collect();
        paths.sort();
        for path in paths {
            if let Ok(contents) = std::fs::read_to_string(&path) {
                files.push((path, contents));
            }
        }
    }
    files
}

/// The impure entry point `main.rs`'s `catalog` subcommand calls: walks
/// the real XDG applications directories and combines what it finds
/// with `policy`, already resolved by the caller the same way
/// `policy dump` resolves it.
#[must_use]
pub fn scan(home: &Path, policy: &ResolvedPolicySet) -> Catalog {
    let files = read_desktop_files(&xdg_applications_dirs(home));
    build_catalog(&files, policy)
}
