//! Diagnostics for the policy pipeline: reading, parsing, merging and
//! validating a `defaults.json` / `overrides.json` pair. Every variant here
//! is something a human can act on directly — a bad JSON file, an app that
//! does not exist, a capability the shipped binary has never heard of — so
//! each carries the context (file path, app id, capability name) needed to
//! fix it without re-running with more logging turned on.
//!
//! This crate uses `miette` rather than `thiserror` or `anyhow`, per house
//! style: a diagnostic is expected to survive to a terminal or a Nix flake
//! check's output and explain itself, not just carry a `Display` impl.
//! `miette::Diagnostic` still requires `std::error::Error` underneath it,
//! so that impl is written by hand below instead of pulling in `thiserror`
//! to derive it.

use std::fmt;
use std::path::PathBuf;

use miette::Diagnostic;

use crate::policy::Tier;

/// Everything that can go wrong while loading, merging or validating a
/// sandbox policy. Each variant is a distinct, actionable failure rather
/// than a wrapped string, so callers (the CLI, the flake check, tests) can
/// match on it instead of grepping the message.
#[derive(Debug, Diagnostic)]
pub enum PolicyError {
    /// The policy file could not be read from disk at all.
    #[diagnostic(code(dots_sandbox::policy::io))]
    Io {
        path: PathBuf,
        source: std::io::Error,
    },

    /// The file's bytes are not valid JSON, or do not match the policy
    /// schema (including an `allow-once` state — see
    /// [`PolicyState`](crate::policy::PolicyState) for why that variant
    /// does not exist to parse into in the first place).
    #[diagnostic(code(dots_sandbox::policy::parse))]
    Parse {
        path: PathBuf,
        source: serde_json::Error,
    },

    /// The file declares a schema `version` this binary does not
    /// understand. Bumping this is a deliberate, breaking change to the
    /// schema, so it is rejected rather than guessed at.
    #[diagnostic(code(dots_sandbox::policy::unsupported_version))]
    UnsupportedVersion {
        path: PathBuf,
        found: u32,
        expected: u32,
    },

    /// `policy dump --app ID` (or an internal resolve) named an app that
    /// the defaults file never defined. Defaults ship the catalog; an app
    /// id that is not in it cannot be resolved, override or no override.
    #[diagnostic(code(dots_sandbox::policy::unknown_app))]
    UnknownApp { app_id: String },

    /// The *defaults* file names a capability this binary does not
    /// recognize. Unlike the same situation in an override (a warn-and-
    /// ignore, since a newer config outliving an older binary is normal),
    /// this is a build-time mismatch between the shipped defaults and the
    /// shipped binary, and must fail loudly.
    #[diagnostic(
        code(dots_sandbox::policy::unknown_capability_in_defaults),
        help(
            "defaults.json ships with this binary; add support for `{capability}` \
             or fix the typo in the shipped defaults file"
        )
    )]
    UnknownCapabilityInDefaults { app_id: String, capability: String },

    /// An app is marked `unconfined` but the required `reason` is missing
    /// or blank. The reason is shown in the Settings UI specifically so an
    /// exemption from sandboxing is visible, never silent.
    #[diagnostic(
        code(dots_sandbox::policy::unconfined_without_reason),
        help("add a non-empty `reason` explaining why `{app_id}` must run unconfined")
    )]
    UnconfinedWithoutReason { app_id: String },

    /// A sandboxed (non-`unconfined`) app in the defaults file has no
    /// `tier`. Every app the defaults catalog ships must resolve to a
    /// concrete sandbox mechanism.
    #[diagnostic(code(dots_sandbox::policy::missing_tier))]
    MissingTier { app_id: String },

    /// A capability was resolved to `allow` on a tier that cannot honestly
    /// express it — for example `postgres` under `vm`, where `PostgreSQL`'s
    /// peer-authentication `SO_PEERCRED` check does not survive being
    /// proxied into a virtual machine. Emitting the bind anyway would look
    /// like it worked and then fail at connect time; refusing at
    /// validation time is the honest failure.
    #[diagnostic(
        code(dots_sandbox::policy::capability_unavailable_on_tier),
        help(
            "`{capability}` has no working expression under the `{tier}` tier for `{app_id}`; \
             either move the app to a different tier or deny the capability"
        )
    )]
    CapabilityUnavailableOnTier {
        app_id: String,
        capability: String,
        tier: Tier,
    },

    /// A resolved policy failed to serialize to JSON. Should not happen
    /// for a well-formed `ResolvedPolicySet`/`ResolvedApp` — every field is
    /// a plain string, path or fieldless enum — but `dots-sandbox policy
    /// dump` still surfaces it as a diagnostic instead of unwrapping,
    /// per house style.
    #[diagnostic(code(dots_sandbox::policy::serialize))]
    Serialize { source: serde_json::Error },
}

impl fmt::Display for PolicyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => {
                write!(f, "failed to read policy file {}: {source}", path.display())
            }
            Self::Parse { path, source } => {
                write!(
                    f,
                    "failed to parse policy file {} as JSON: {source}",
                    path.display()
                )
            }
            Self::UnsupportedVersion {
                path,
                found,
                expected,
            } => write!(
                f,
                "policy file {} has schema version {found}, this binary understands {expected}",
                path.display()
            ),
            Self::UnknownApp { app_id } => {
                write!(f, "app `{app_id}` is not defined in the defaults policy")
            }
            Self::UnknownCapabilityInDefaults { app_id, capability } => write!(
                f,
                "defaults policy for app `{app_id}` names unknown capability `{capability}`"
            ),
            Self::UnconfinedWithoutReason { app_id } => {
                write!(f, "app `{app_id}` is marked unconfined but has no reason")
            }
            Self::MissingTier { app_id } => {
                write!(f, "sandboxed app `{app_id}` in defaults has no `tier`")
            }
            Self::CapabilityUnavailableOnTier {
                app_id,
                capability,
                tier,
            } => write!(
                f,
                "app `{app_id}` resolves capability `{capability}` to allow, but `{tier}` \
                 cannot express it"
            ),
            Self::Serialize { source } => {
                write!(f, "failed to serialize resolved policy: {source}")
            }
        }
    }
}

impl std::error::Error for PolicyError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Parse { source, .. } | Self::Serialize { source } => Some(source),
            _ => None,
        }
    }
}
