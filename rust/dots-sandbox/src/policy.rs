//! The sandbox policy model: parsing a `defaults.json` / `overrides.json`
//! pair, merging them per app, and resolving the result into the typed
//! [`ResolvedPolicy`] that [`crate::argv::spawn_argv`] turns into a command
//! line.
//!
//! Two files, two roles. Defaults ship read-only from Nix — see
//! `$DOTS_SANDBOX_DEFAULTS` in the binary's own help text — and define the
//! full app catalog and the full capability vocabulary; a mismatch there is
//! a build problem, so it fails loudly. Overrides are a plain per-user file
//! written by the Settings page and the prompter; they may only narrow or
//! widen capabilities the defaults already know about, never introduce new
//! ones, so an override the running binary does not recognize is a
//! forward-compatibility signal (a newer config, an older binary) and is
//! ignored with a warning rather than treated as an error.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::PolicyError;

/// The schema version this binary understands. Bumping the schema is a
/// deliberate, breaking change, so an unrecognized version is rejected
/// rather than guessed at.
pub const SUPPORTED_VERSION: u32 = 1;

/// A capability's persisted state. `allow-once` is deliberately not a
/// variant here: it is a prompt answer that belongs to the session-state
/// layer (`$XDG_RUNTIME_DIR/dots-sandbox/`, not this task's concern beyond
/// leaving room for it), never to a file Nix or the Settings page writes.
/// Because this is a plain three-variant enum, `serde` already refuses to
/// deserialize anything else — including `allow-once` — with a message
/// naming the valid variants, which is exactly the rejection the schema
/// needs and the file that carries it is malformed as far as this binary
/// is concerned.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PolicyState {
    Allow,
    Deny,
    Ask,
}

/// Which sandbox mechanism an app runs under. See `crate::argv` for what
/// each tier actually emits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    Container,
    Vm,
}

impl fmt::Display for Tier {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Container => "container",
            Self::Vm => "vm",
        })
    }
}

/// Read/write mode for an explicit per-path grant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PathMode {
    Rw,
    Ro,
}

/// The fixed vocabulary of capability names a policy file may use. This is
/// deliberately not a `#[derive(Deserialize)]` enum: an unknown name needs
/// two different reactions depending on which file it came from (hard
/// error in defaults, warn-and-ignore in overrides — rule 3 of the merge),
/// and a derived enum deserialization can only ever produce one of those.
/// So policy files carry capability names as plain `String` keys, and
/// [`Capability::parse`] is called explicitly wherever the merge needs to
/// tell the two cases apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Capability {
    Net,
    NixDaemon,
    RepoRead,
    RepoWrite,
    Postgres,
    SettingsRo,
    Kvm,
}

impl Capability {
    /// Every capability this binary knows how to translate into argv.
    pub const ALL: [Capability; 7] = [
        Capability::Net,
        Capability::NixDaemon,
        Capability::RepoRead,
        Capability::RepoWrite,
        Capability::Postgres,
        Capability::SettingsRo,
        Capability::Kvm,
    ];

    /// Capabilities `vm` cannot honestly express (see the `postgres` note
    /// in the task brief on `SO_PEERCRED` not surviving into a VM; the same
    /// reasoning applies to a raw device node and a host daemon socket that
    /// only make sense inside a shared kernel namespace).
    const VM_UNAVAILABLE: [Capability; 3] =
        [Capability::NixDaemon, Capability::Postgres, Capability::Kvm];

    #[must_use]
    pub fn parse(name: &str) -> Option<Capability> {
        Some(match name {
            "net" => Capability::Net,
            "nix-daemon" => Capability::NixDaemon,
            "repo-read" => Capability::RepoRead,
            "repo-write" => Capability::RepoWrite,
            "postgres" => Capability::Postgres,
            "settings-ro" => Capability::SettingsRo,
            "kvm" => Capability::Kvm,
            _ => return None,
        })
    }

    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Capability::Net => "net",
            Capability::NixDaemon => "nix-daemon",
            Capability::RepoRead => "repo-read",
            Capability::RepoWrite => "repo-write",
            Capability::Postgres => "postgres",
            Capability::SettingsRo => "settings-ro",
            Capability::Kvm => "kvm",
        }
    }

    /// The name a person reads in the permissions UI.
    ///
    /// Lives here, beside the variant, rather than in the QML that renders
    /// it. A label table in the frontend is a second source of truth: it
    /// drifts silently when a capability is added or renamed here, and the
    /// page then shows a stale name, or omits the capability entirely, with
    /// nothing failing to announce it.
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Capability::Net => "Network",
            Capability::NixDaemon => "Nix daemon",
            Capability::RepoRead => "Repository (read)",
            Capability::RepoWrite => "Repository (write)",
            Capability::Postgres => "PostgreSQL",
            Capability::SettingsRo => "System settings (read)",
            Capability::Kvm => "Hardware virtualisation",
        }
    }

    /// One line saying what granting this actually hands over.
    ///
    /// Phrased as the concrete access rather than the mechanism, because the
    /// reader is deciding whether an app should have it, not implementing it.
    #[must_use]
    pub fn description(self) -> &'static str {
        match self {
            Capability::Net => "Reach the internet and services on the local network",
            Capability::NixDaemon => "Build and install packages through the system Nix daemon",
            Capability::RepoRead => "Read this dotfiles checkout",
            Capability::RepoWrite => "Modify files in this dotfiles checkout",
            Capability::Postgres => "Query the local database over its Unix socket",
            Capability::SettingsRo => "Read this machine's settings, including its hostname and accounts",
            Capability::Kvm => "Use /dev/kvm to run a virtual machine",
        }
    }
}

/// One entry of the `paths` array a policy file may attach to an app, as
/// written to disk: an unexpanded `~`-relative or absolute path string.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RawPathGrant {
    pub path: String,
    pub mode: PathMode,
    pub state: PolicyState,
}

/// One app entry as written to disk, before any merge has happened. Every
/// field is optional because both the defaults role (which must fill in
/// `tier` for every sandboxed app) and the overrides role (which may touch
/// only a handful of capabilities for a handful of apps) share this same
/// shape; which fields are actually required depends on which of the two
/// files this value came from, and is enforced by the callers in this
/// module rather than by `serde`.
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct RawAppPolicy {
    #[serde(default)]
    pub unconfined: bool,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub tier: Option<Tier>,
    #[serde(default)]
    pub caps: BTreeMap<String, PolicyState>,
    #[serde(default)]
    pub paths: Vec<RawPathGrant>,
}

/// A whole `defaults.json` or `overrides.json`, parsed but not yet merged.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PolicyFile {
    pub version: u32,
    #[serde(default)]
    pub apps: BTreeMap<String, RawAppPolicy>,
    #[serde(rename = "denyPaths", default)]
    pub deny_paths: Vec<String>,
}

/// Parses a policy file's already-read contents and checks its schema
/// version. Reading the file from disk is left to the caller (the CLI's
/// `main.rs`) so this module never touches the filesystem itself.
///
/// # Errors
///
/// Returns [`PolicyError::Parse`] if `contents` is not valid JSON or does
/// not match the policy schema (including a rejected `allow-once` state),
/// and [`PolicyError::UnsupportedVersion`] if `version` is not
/// [`SUPPORTED_VERSION`].
pub fn parse_policy_file(path: &Path, contents: &str) -> Result<PolicyFile, PolicyError> {
    let file: PolicyFile = serde_json::from_str(contents).map_err(|source| PolicyError::Parse {
        path: path.to_path_buf(),
        source,
    })?;
    if file.version != SUPPORTED_VERSION {
        return Err(PolicyError::UnsupportedVersion {
            path: path.to_path_buf(),
            found: file.version,
            expected: SUPPORTED_VERSION,
        });
    }
    Ok(file)
}

/// An app after `~` and `denyPaths` resolution: an absolute path, no longer
/// tied to whichever home directory produced it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedPathGrant {
    pub path: PathBuf,
    pub mode: PathMode,
    pub state: PolicyState,
}

/// The fully merged, resolved policy for one sandboxed app: exactly what
/// [`crate::argv::spawn_argv`] needs, and nothing it would have to go back
/// to a config file or the filesystem to find out.
#[derive(Debug, Clone, Serialize)]
pub struct ResolvedPolicy {
    pub tier: Tier,
    pub capabilities: BTreeMap<Capability, PolicyState>,
    pub paths: Vec<ResolvedPathGrant>,
}

/// The two shapes an app entry can resolve to: sandboxed under a tier, or
/// exempt from sandboxing entirely with a visible reason.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum ResolvedApp {
    Sandboxed(ResolvedPolicy),
    Unconfined { reason: String },
}

/// The merged, resolved policy for every app the defaults catalog defines —
/// what `dots-sandbox policy dump` (without `--app`) prints as JSON.
#[derive(Debug, Clone, Serialize)]
pub struct ResolvedPolicySet {
    pub version: u32,
    #[serde(rename = "denyPaths")]
    pub deny_paths: Vec<PathBuf>,
    pub apps: BTreeMap<String, ResolvedApp>,
}

/// Expands a leading `~` or `~/` in a policy-file path string against the
/// given home directory. A pure string/path substitution, not a filesystem
/// lookup: the home directory is a parameter here, never read from the
/// environment, so this stays testable without a real `$HOME` and callable
/// from the same pure resolution path `spawn_argv` itself follows.
fn expand_tilde(raw: &str, home_dir: &Path) -> PathBuf {
    raw.strip_prefix("~/").map_or_else(
        || {
            if raw == "~" {
                home_dir.to_path_buf()
            } else {
                PathBuf::from(raw)
            }
        },
        |rest| home_dir.join(rest),
    )
}

/// Rule 4: does `candidate` fall under a denied path, exactly or as a
/// descendant? Compared component-wise via [`Path::starts_with`], not by
/// string prefix, so `~/.ssh-backup` is not mistaken for a descendant of
/// `~/.ssh`.
fn is_denied(candidate: &Path, deny_paths: &[PathBuf]) -> bool {
    deny_paths
        .iter()
        .any(|denied| candidate.starts_with(denied))
}

/// Rule 5, checked once the caller already knows `unconfined` is set:
/// the reason must be present and non-blank.
fn require_reason(app_id: &str, reason: Option<String>) -> Result<String, PolicyError> {
    reason
        .filter(|r| !r.trim().is_empty())
        .ok_or_else(|| PolicyError::UnconfinedWithoutReason {
            app_id: app_id.to_string(),
        })
}

/// The note on `postgres` under `vm`, generalized: refuse at
/// validation/resolution time rather than emit a bind that will not work,
/// for every capability the `vm` tier cannot honestly express.
fn check_tier_compatibility(
    app_id: &str,
    tier: Tier,
    capabilities: &BTreeMap<Capability, PolicyState>,
) -> Result<(), PolicyError> {
    if tier != Tier::Vm {
        return Ok(());
    }
    for cap in Capability::VM_UNAVAILABLE {
        if capabilities.get(&cap) == Some(&PolicyState::Allow) {
            return Err(PolicyError::CapabilityUnavailableOnTier {
                app_id: app_id.to_string(),
                capability: cap.as_str().to_string(),
                tier,
            });
        }
    }
    Ok(())
}

/// Validates a single policy file under **defaults semantics**: every
/// capability name it uses must be one this binary recognizes, every
/// `unconfined` app must carry a reason, every sandboxed app must name a
/// tier, and no capability may resolve to `allow` on a tier that cannot
/// express it. `policy validate` runs this directly against the file the
/// Nix flake check builds; there is no overrides layer to merge in at that
/// point, since a build has no user session that could have written one.
///
/// # Errors
///
/// Returns the first of [`PolicyError::UnconfinedWithoutReason`],
/// [`PolicyError::MissingTier`], [`PolicyError::UnknownCapabilityInDefaults`]
/// or [`PolicyError::CapabilityUnavailableOnTier`] it finds, in that order
/// per app, iterated in the file's app-id order.
pub fn validate_strict(file: &PolicyFile) -> Result<(), PolicyError> {
    for (app_id, app) in &file.apps {
        if app.unconfined {
            require_reason(app_id, app.reason.clone())?;
            continue;
        }
        let tier = app.tier.ok_or_else(|| PolicyError::MissingTier {
            app_id: app_id.clone(),
        })?;
        let mut capabilities = BTreeMap::new();
        for (name, state) in &app.caps {
            let cap = Capability::parse(name).ok_or_else(|| {
                PolicyError::UnknownCapabilityInDefaults {
                    app_id: app_id.clone(),
                    capability: name.clone(),
                }
            })?;
            capabilities.insert(cap, *state);
        }
        check_tier_compatibility(app_id, tier, &capabilities)?;
    }
    Ok(())
}

/// Merges the `caps` map of one app across the two layers: defaults first,
/// then overrides key-wise on top (rule 1), with an unknown override
/// capability logged and dropped rather than rejected (rule 3). An unknown
/// *defaults* capability is a hard error, checked by the caller before this
/// runs, since defaults ship with the binary and a mismatch there is a
/// build problem, not a forward-compatibility signal.
fn merge_capabilities(
    app_id: &str,
    default_app: &RawAppPolicy,
    override_app: Option<&RawAppPolicy>,
) -> Result<BTreeMap<Capability, PolicyState>, PolicyError> {
    let mut capabilities = BTreeMap::new();
    for (name, state) in &default_app.caps {
        let cap =
            Capability::parse(name).ok_or_else(|| PolicyError::UnknownCapabilityInDefaults {
                app_id: app_id.to_string(),
                capability: name.clone(),
            })?;
        capabilities.insert(cap, *state);
    }
    if let Some(o) = override_app {
        for (name, state) in &o.caps {
            if let Some(cap) = Capability::parse(name) {
                capabilities.insert(cap, *state);
            } else {
                tracing::warn!(
                    app_id,
                    capability = name.as_str(),
                    "ignoring unknown capability in override policy"
                );
            }
        }
    }
    Ok(capabilities)
}

/// Merges the `paths` array of one app across the two layers, key-wise by
/// the `path` string itself (the same rule-1 philosophy the capability map
/// gets, applied to per-path grants): an override entry for a path
/// defaults already grants replaces that entry outright, entries only one
/// layer has pass through unchanged. Every resulting path is then
/// `~`-expanded and checked against `deny_paths`, which always wins over
/// `allow` (rule 4), regardless of which layer, or neither, granted it.
fn merge_paths(
    default_app: &RawAppPolicy,
    override_app: Option<&RawAppPolicy>,
    home_dir: &Path,
    deny_paths: &[PathBuf],
) -> Vec<ResolvedPathGrant> {
    let mut by_path: BTreeMap<&str, &RawPathGrant> = default_app
        .paths
        .iter()
        .map(|p| (p.path.as_str(), p))
        .collect();
    if let Some(o) = override_app {
        for p in &o.paths {
            by_path.insert(p.path.as_str(), p);
        }
    }
    by_path
        .into_values()
        .map(|raw| {
            let expanded = expand_tilde(&raw.path, home_dir);
            let state = if is_denied(&expanded, deny_paths) {
                PolicyState::Deny
            } else {
                raw.state
            };
            ResolvedPathGrant {
                path: expanded,
                mode: raw.mode,
                state,
            }
        })
        .collect()
}

/// Rule 4's `denyPaths` themselves: the union of both layers, each
/// `~`-expanded against `home_dir`, deduplicated. `denyPaths` is additive
/// across layers on purpose — an override can only ever add more denied
/// paths, never remove one the defaults already denied.
fn merged_deny_paths(
    defaults: &PolicyFile,
    overrides: &PolicyFile,
    home_dir: &Path,
) -> Vec<PathBuf> {
    let mut deny_paths: Vec<PathBuf> = defaults
        .deny_paths
        .iter()
        .map(|p| expand_tilde(p, home_dir))
        .collect();
    for raw in &overrides.deny_paths {
        let expanded = expand_tilde(raw, home_dir);
        if !deny_paths.contains(&expanded) {
            deny_paths.push(expanded);
        }
    }
    deny_paths
}

/// Resolves one app: looks it up in the defaults catalog (an app absent
/// there cannot be resolved, override or no override), merges in whatever
/// the overrides layer says, and returns either a fully resolved
/// [`ResolvedPolicy`] or an unconfined exemption with its reason.
///
/// # Errors
///
/// Returns [`PolicyError::UnknownApp`] if `app_id` is not in `defaults`, or
/// any merge-time error the resolution can produce: a missing tier, an
/// unknown defaults capability, an unconfined app without a reason, or a
/// capability that cannot be honestly expressed on its tier.
pub fn resolve_app(
    defaults: &PolicyFile,
    overrides: &PolicyFile,
    app_id: &str,
    home_dir: &Path,
) -> Result<ResolvedApp, PolicyError> {
    let default_app = defaults
        .apps
        .get(app_id)
        .ok_or_else(|| PolicyError::UnknownApp {
            app_id: app_id.to_string(),
        })?;
    let override_app = overrides.apps.get(app_id);
    let deny_paths = merged_deny_paths(defaults, overrides, home_dir);
    resolve_one(app_id, default_app, override_app, home_dir, &deny_paths)
}

/// The shared resolution step behind both [`resolve_app`] and
/// [`resolve_all`], taking the already-computed `deny_paths` so a full-set
/// resolve does not recompute the union once per app.
fn resolve_one(
    app_id: &str,
    default_app: &RawAppPolicy,
    override_app: Option<&RawAppPolicy>,
    home_dir: &Path,
    deny_paths: &[PathBuf],
) -> Result<ResolvedApp, PolicyError> {
    // Rule 5, applied across layers: whichever layer opts into `unconfined`
    // governs, together with its own reason. An override may add an
    // exemption the defaults did not grant; if neither layer opts in, the
    // app is sandboxed normally.
    let (unconfined, reason) = match override_app.filter(|o| o.unconfined) {
        Some(o) => (true, o.reason.clone()),
        None if default_app.unconfined => (true, default_app.reason.clone()),
        None => (false, None),
    };
    if unconfined {
        let reason = require_reason(app_id, reason)?;
        return Ok(ResolvedApp::Unconfined { reason });
    }

    let tier = override_app
        .and_then(|o| o.tier)
        .or(default_app.tier)
        .ok_or_else(|| PolicyError::MissingTier {
            app_id: app_id.to_string(),
        })?;
    let capabilities = merge_capabilities(app_id, default_app, override_app)?;
    check_tier_compatibility(app_id, tier, &capabilities)?;
    let paths = merge_paths(default_app, override_app, home_dir, deny_paths);
    Ok(ResolvedApp::Sandboxed(ResolvedPolicy {
        tier,
        capabilities,
        paths,
    }))
}

/// Resolves every app the defaults catalog defines, applying whatever the
/// overrides layer says for each. What `dots-sandbox policy dump` prints
/// when run without `--app`.
///
/// # Errors
///
/// Returns the first merge-time error any app in `defaults` produces (see
/// [`resolve_app`]'s errors); resolution stops at the first failing app
/// rather than collecting every app's errors at once.
pub fn resolve_all(
    defaults: &PolicyFile,
    overrides: &PolicyFile,
    home_dir: &Path,
) -> Result<ResolvedPolicySet, PolicyError> {
    let deny_paths = merged_deny_paths(defaults, overrides, home_dir);
    let apps = defaults
        .apps
        .iter()
        .map(|(app_id, default_app)| {
            let override_app = overrides.apps.get(app_id);
            resolve_one(app_id, default_app, override_app, home_dir, &deny_paths)
                .map(|resolved| (app_id.clone(), resolved))
        })
        .collect::<Result<_, _>>()?;
    Ok(ResolvedPolicySet {
        version: defaults.version,
        deny_paths,
        apps,
    })
}

/// An empty policy file, used as the overrides layer when
/// `~/.config/dots-sandbox/overrides.json` does not exist yet — the normal
/// state for a user who has never opened the Settings sandbox page or been
/// prompted.
#[must_use]
pub fn empty_overrides(version: u32) -> PolicyFile {
    PolicyFile {
        version,
        apps: BTreeMap::new(),
        deny_paths: Vec::new(),
    }
}
