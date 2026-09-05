//! MERGE-DELETE: stand-ins for the policy module built in parallel.
//! Every item here is replaced at merge time by the real definitions in
//! policy.rs / caps.rs / argv.rs. Do not add logic here.
//!
//! `spawn_argv`'s signature is the contract handed to both halves of this
//! crate and is reproduced exactly. Everything else in this file — the
//! shape of `ResolvedPolicy`, `LaunchCtx`, `Tier`, `CapState`, `PathGrant`,
//! `Unconfined`, and the `resolve_policy` stub — is this task's own guess
//! at what the policy half will look like, kept just detailed enough to
//! exercise `launch.rs`, `broker.rs` and `grants.rs` against something
//! real. None of it is binding; see the "merge negotiation" section of
//! this task's report for the exact list of what was invented here.
//!
//! `spawn_argv` itself is intentionally trivial: it runs `ctx.program`
//! with `ctx.args` completely unwrapped, ignoring `resolved` altogether.
//! The real one will wrap this in `systemd-nspawn --user`/`systemd-vmspawn`
//! invocations; this stub only needs to hand `launch.rs` something that
//! actually runs, so the spawn/signal-forwarding/exit-code plumbing can be
//! tested against a real child process and real signals.

use std::collections::BTreeMap;
use std::path::PathBuf;

pub use policy_error::PolicyError;

/// An app's sandboxing depth. Namesake fields only — the real enum may
/// carry more than these two tiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Container,
    Vm,
}

/// The resolved disposition of one capability.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapState {
    Allow,
    Deny,
    Ask,
}

/// One path bind-mounted (or bind-mountable) into the sandbox.
#[derive(Debug, Clone)]
pub struct PathGrant {
    pub host_path: PathBuf,
    pub sandbox_path: PathBuf,
    pub read_only: bool,
}

/// Present when a policy opts an app out of sandboxing entirely; carries
/// the reason so it can be surfaced (and audited — see `broker.rs`).
#[derive(Debug, Clone)]
pub struct Unconfined {
    pub reason: String,
}

/// An app's fully resolved policy, as `spawn_argv` and the broker see it.
#[derive(Debug, Clone)]
pub struct ResolvedPolicy {
    pub tier: Tier,
    pub capabilities: BTreeMap<String, CapState>,
    pub path_grants: Vec<PathGrant>,
    pub unconfined: Option<Unconfined>,
}

/// Everything `spawn_argv` needs, injected rather than read from the
/// environment or filesystem so the function stays pure and testable.
#[derive(Debug, Clone)]
pub struct LaunchCtx {
    pub home: PathBuf,
    pub runtime_dir: PathBuf,
    pub repo_root: PathBuf,
    pub grant_share_dir: PathBuf,
    pub machine_name: String,
    pub program: String,
    pub args: Vec<String>,
}

/// The contract signature. Do not change without checking with the
/// parallel task — this is the one piece both halves were told exactly.
#[must_use]
pub fn spawn_argv(_resolved: &ResolvedPolicy, ctx: &LaunchCtx) -> Vec<String> {
    let mut argv = Vec::with_capacity(ctx.args.len() + 1);
    argv.push(ctx.program.clone());
    argv.extend(ctx.args.iter().cloned());
    argv
}

/// Invented: the contract only fixed `spawn_argv`'s signature, not how an
/// app id becomes a `ResolvedPolicy`. `run` needs some such function to
/// call, so this stand-in always succeeds with a fixed, permissive
/// policy, except for the one sentinel id used to exercise the error
/// path in tests.
///
/// # Errors
///
/// Returns an error for an empty `app_id`; every other id succeeds.
pub fn resolve_policy(app_id: &str) -> Result<ResolvedPolicy, PolicyError> {
    if app_id.is_empty() {
        return Err(PolicyError::UnknownApp(app_id.to_owned()));
    }
    let mut capabilities = BTreeMap::new();
    capabilities.insert("network".to_owned(), CapState::Allow);
    capabilities.insert("camera".to_owned(), CapState::Ask);
    capabilities.insert("gpu".to_owned(), CapState::Deny);
    Ok(ResolvedPolicy {
        tier: Tier::Container,
        capabilities,
        path_grants: Vec::new(),
        unconfined: None,
    })
}

/// MERGE-DELETE: co-located with the rest of this stub rather than given
/// its own file, since it exists only to make `resolve_policy` above
/// compile — the real error type lives wherever policy.rs puts it. No
/// `thiserror`: this crate's house rule is `miette` diagnostics without
/// it, so `Display`/`Error` are hand-rolled and `miette::Diagnostic` is
/// derived on top for the `help()` text.
mod policy_error {
    use miette::Diagnostic;

    #[derive(Debug, Diagnostic)]
    pub enum PolicyError {
        #[diagnostic(help("this stub only recognizes non-empty app ids"))]
        UnknownApp(String),
    }

    impl std::fmt::Display for PolicyError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                Self::UnknownApp(id) => write!(f, "no policy for app {id:?}"),
            }
        }
    }

    impl std::error::Error for PolicyError {}
}
