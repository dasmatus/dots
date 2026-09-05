//! One test per numbered merge rule in the task brief, plus the tier-
//! compatibility check the `postgres`/`vm` note calls for. These are the
//! security properties of the policy model: `allow-once` rejection and
//! `denyPaths` precedence matter most, since together they are what stops
//! a prompt (or a bug in one) from silently handing over `~/.ssh`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use dots_sandbox::policy::{
    self, Capability, PathMode, PolicyFile, PolicyState, RawAppPolicy, RawPathGrant, ResolvedApp,
    Tier,
};

fn home() -> PathBuf {
    PathBuf::from("/home/tester")
}

fn empty_file(version: u32) -> PolicyFile {
    PolicyFile {
        version,
        apps: BTreeMap::new(),
        deny_paths: Vec::new(),
    }
}

fn sandboxed_app(tier: Tier, caps: &[(&str, PolicyState)]) -> RawAppPolicy {
    RawAppPolicy {
        unconfined: false,
        reason: None,
        tier: Some(tier),
        caps: caps
            .iter()
            .map(|(name, state)| ((*name).to_string(), *state))
            .collect(),
        paths: Vec::new(),
    }
}

/// Rule 1: overrides layer key-wise per app per capability. An override
/// naming one capability must not discard the app's other capabilities.
#[test]
fn override_merges_one_capability_without_discarding_the_rest() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "nix-lint".to_string(),
        sandboxed_app(
            Tier::Container,
            &[
                (Capability::Net.as_str(), PolicyState::Allow),
                (Capability::NixDaemon.as_str(), PolicyState::Allow),
                (Capability::RepoWrite.as_str(), PolicyState::Allow),
            ],
        ),
    );

    let mut overrides = empty_file(1);
    overrides.apps.insert(
        "nix-lint".to_string(),
        RawAppPolicy {
            caps: [(Capability::Net.as_str().to_string(), PolicyState::Deny)]
                .into_iter()
                .collect(),
            ..RawAppPolicy::default()
        },
    );

    let ResolvedApp::Sandboxed(resolved) =
        policy::resolve_app(&defaults, &overrides, "nix-lint", &home()).expect("resolves")
    else {
        panic!("expected a sandboxed app");
    };

    assert_eq!(
        resolved.capabilities.get(&Capability::Net),
        Some(&PolicyState::Deny)
    );
    assert_eq!(
        resolved.capabilities.get(&Capability::NixDaemon),
        Some(&PolicyState::Allow)
    );
    assert_eq!(
        resolved.capabilities.get(&Capability::RepoWrite),
        Some(&PolicyState::Allow)
    );
}

/// Rule 2: `allow-once` must not be representable in a persisted policy.
/// A file naming it is rejected outright, not silently downgraded to
/// `allow`.
#[test]
fn allow_once_in_a_persisted_file_is_rejected() {
    let contents = r#"{
        "version": 1,
        "apps": {
            "nix-lint": {
                "tier": "container",
                "caps": { "net": "allow-once" }
            }
        }
    }"#;

    let err = policy::parse_policy_file(Path::new("defaults.json"), contents)
        .expect_err("`allow-once` must not parse as a persisted capability state");
    let message = err.to_string();
    assert!(
        message.contains("defaults.json"),
        "error should name the offending file, got: {message}"
    );
}

/// Rule 3, override half: an unknown capability name in an override warns
/// and is ignored, so a newer config does not break an older binary — the
/// app still resolves, just without the capability this binary has never
/// heard of.
#[test]
fn unknown_capability_in_override_is_ignored_not_rejected() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "nix-lint".to_string(),
        sandboxed_app(Tier::Container, &[("net", PolicyState::Allow)]),
    );

    let mut overrides = empty_file(1);
    overrides.apps.insert(
        "nix-lint".to_string(),
        RawAppPolicy {
            caps: [("some-future-capability".to_string(), PolicyState::Allow)]
                .into_iter()
                .collect(),
            ..RawAppPolicy::default()
        },
    );

    let ResolvedApp::Sandboxed(resolved) =
        policy::resolve_app(&defaults, &overrides, "nix-lint", &home())
            .expect("must still resolve")
    else {
        panic!("expected a sandboxed app");
    };

    assert_eq!(
        resolved.capabilities.get(&Capability::Net),
        Some(&PolicyState::Allow)
    );
    assert_eq!(
        resolved.capabilities.len(),
        1,
        "the unknown capability must not appear at all"
    );
}

/// Rule 3, defaults half: an unknown capability in the defaults is an
/// error, since defaults ship with the binary and a mismatch there is a
/// build problem, not a forward-compatibility signal.
#[test]
fn unknown_capability_in_defaults_is_an_error() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "nix-lint".to_string(),
        sandboxed_app(
            Tier::Container,
            &[("not-a-real-capability", PolicyState::Allow)],
        ),
    );
    let overrides = empty_file(1);

    let err = policy::resolve_app(&defaults, &overrides, "nix-lint", &home())
        .expect_err("an unrecognized defaults capability must fail resolution");
    assert!(matches!(
        err,
        dots_sandbox::error::PolicyError::UnknownCapabilityInDefaults { .. }
    ));

    assert!(
        policy::validate_strict(&defaults).is_err(),
        "`policy validate` must also reject it"
    );
}

/// Rule 4: `denyPaths` wins over any `allow` on a path, always — the
/// property that stops a prompt from handing over `~/.ssh` however the
/// user clicks.
#[test]
fn deny_paths_overrides_an_explicit_allow() {
    let mut defaults = empty_file(1);
    defaults.deny_paths.push("~/.ssh".to_string());
    defaults.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            tier: Some(Tier::Container),
            paths: vec![RawPathGrant {
                path: "~/.ssh".to_string(),
                mode: PathMode::Rw,
                state: PolicyState::Allow,
            }],
            ..RawAppPolicy::default()
        },
    );
    let overrides = empty_file(1);

    let ResolvedApp::Sandboxed(resolved) =
        policy::resolve_app(&defaults, &overrides, "enroll-fido", &home()).expect("resolves")
    else {
        panic!("expected a sandboxed app");
    };

    let ssh_grant = resolved
        .paths
        .iter()
        .find(|g| g.path == home().join(".ssh"))
        .expect("the ~/.ssh grant must still be present, just forced to deny");
    assert_eq!(
        ssh_grant.state,
        PolicyState::Deny,
        "denyPaths must win over the app's own allow, no matter how it clicked its way there"
    );
}

/// Rule 4, override side: hand-editing the override file to grant a
/// denied path is the documented escape hatch — `denyPaths` from the
/// *defaults* layer must not block a path that is only denied nowhere at
/// all once the user has edited their own file. This test instead checks
/// the layer `denyPaths` itself comes from is additive: an override cannot
/// remove a defaults-level deny by simply not repeating it.
#[test]
fn deny_paths_from_defaults_cannot_be_silently_dropped_by_overrides() {
    let mut defaults = empty_file(1);
    defaults.deny_paths.push("~/.ssh".to_string());
    defaults.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            tier: Some(Tier::Container),
            ..RawAppPolicy::default()
        },
    );

    let mut overrides = empty_file(1);
    // The override grants ~/.ssh directly to the app, without repeating
    // (or being able to remove) the defaults' denyPaths entry.
    overrides.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            paths: vec![RawPathGrant {
                path: "~/.ssh".to_string(),
                mode: PathMode::Ro,
                state: PolicyState::Allow,
            }],
            ..RawAppPolicy::default()
        },
    );

    let ResolvedApp::Sandboxed(resolved) =
        policy::resolve_app(&defaults, &overrides, "enroll-fido", &home()).expect("resolves")
    else {
        panic!("expected a sandboxed app");
    };
    let ssh_grant = resolved
        .paths
        .iter()
        .find(|g| g.path == home().join(".ssh"))
        .expect("grant present");
    assert_eq!(ssh_grant.state, PolicyState::Deny);
}

/// Rule 5: `unconfined: true` requires a non-empty `reason`.
#[test]
fn unconfined_without_reason_is_rejected() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            unconfined: true,
            reason: None,
            ..RawAppPolicy::default()
        },
    );
    let overrides = empty_file(1);

    let err = policy::resolve_app(&defaults, &overrides, "enroll-fido", &home())
        .expect_err("unconfined without a reason must be rejected");
    assert!(matches!(
        err,
        dots_sandbox::error::PolicyError::UnconfinedWithoutReason { .. }
    ));
}

/// Rule 5, positive case: a non-empty reason is accepted and carried
/// through to the resolved policy, since it is shown in the Settings UI.
#[test]
fn unconfined_with_reason_resolves_and_keeps_the_reason_visible() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            unconfined: true,
            reason: Some("needs raw /dev/hidraw and a physical key tap".to_string()),
            ..RawAppPolicy::default()
        },
    );
    let overrides = empty_file(1);

    let resolved =
        policy::resolve_app(&defaults, &overrides, "enroll-fido", &home()).expect("resolves");
    match resolved {
        ResolvedApp::Unconfined { reason } => {
            assert_eq!(reason, "needs raw /dev/hidraw and a physical key tap");
        }
        ResolvedApp::Sandboxed(_) => panic!("expected an unconfined app"),
    }
}

/// A whitespace-only reason is exactly as absent as no reason at all:
/// the visibility rule 5 asks for is defeated just as thoroughly by a
/// reason a human cannot read as by a missing one.
#[test]
fn unconfined_with_blank_reason_is_rejected() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "enroll-fido".to_string(),
        RawAppPolicy {
            unconfined: true,
            reason: Some("   ".to_string()),
            ..RawAppPolicy::default()
        },
    );
    let overrides = empty_file(1);

    let err = policy::resolve_app(&defaults, &overrides, "enroll-fido", &home())
        .expect_err("a blank reason must be rejected the same as a missing one");
    assert!(matches!(
        err,
        dots_sandbox::error::PolicyError::UnconfinedWithoutReason { .. }
    ));
}

/// The `postgres`/`vm` note: a capability that cannot be honestly
/// expressed on a tier is refused at resolution time rather than silently
/// producing an argv that will fail at connect time.
#[test]
fn postgres_allow_on_vm_tier_is_rejected_at_resolution() {
    let mut defaults = empty_file(1);
    defaults.apps.insert(
        "some-vm-app".to_string(),
        sandboxed_app(Tier::Vm, &[("postgres", PolicyState::Allow)]),
    );
    let overrides = empty_file(1);

    let err = policy::resolve_app(&defaults, &overrides, "some-vm-app", &home())
        .expect_err("postgres must not resolve to allow under the vm tier");
    assert!(matches!(
        err,
        dots_sandbox::error::PolicyError::CapabilityUnavailableOnTier { .. }
    ));
}

/// An unknown app id (not defined anywhere in the defaults catalog) cannot
/// be resolved, override or no override — defaults ship the catalog.
#[test]
fn unknown_app_id_is_rejected() {
    let defaults = empty_file(1);
    let overrides = empty_file(1);
    let err = policy::resolve_app(&defaults, &overrides, "does-not-exist", &home())
        .expect_err("an app absent from defaults cannot resolve");
    assert!(matches!(
        err,
        dots_sandbox::error::PolicyError::UnknownApp { .. }
    ));
}
