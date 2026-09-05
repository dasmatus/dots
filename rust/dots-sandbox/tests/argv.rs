//! Tests for `dots_sandbox::argv::spawn_argv`: the pure translation from a
//! resolved policy to a `systemd-nspawn`/`systemd-vmspawn` argv. Every
//! assertion here is against the argv `Vec<String>` itself — never a
//! joined string — so a quoting change in how a flag is built would show
//! up as an element-by-element mismatch instead of silently passing.

use std::collections::BTreeMap;
use std::path::PathBuf;

use dots_sandbox::argv::{spawn_argv, LaunchCtx};
use dots_sandbox::policy::{
    Capability, PathMode, PolicyState, ResolvedPathGrant, ResolvedPolicy, Tier,
};

/// A `LaunchCtx` with distinct, recognizable paths for every field, so a
/// test failure names exactly which one leaked into the wrong place.
fn ctx() -> LaunchCtx {
    LaunchCtx {
        home_dir: PathBuf::from("/home/tester"),
        runtime_dir: PathBuf::from("/run/user/1000"),
        repo_root: PathBuf::from("/home/tester/dots"),
        grant_share_dir: PathBuf::from("/run/user/1000/dots-sandbox/grants/nix-lint"),
        machine_name: "nix-lint".to_string(),
        container_rootfs: PathBuf::from("/var/lib/dots-sandbox/container-rootfs"),
        vm_kernel: PathBuf::from("/var/lib/dots-sandbox/vmlinuz-sandbox"),
        vm_firmware: PathBuf::from("/nix/store/example-OVMF/FV/OVMF_CODE.fd"),
        program: "nix".to_string(),
        args: vec!["flake".to_string(), "check".to_string()],
    }
}

/// A resolved policy with every capability explicitly denied, and no extra
/// path grants — the baseline every "present when granted" test starts
/// from and flips exactly one capability off of.
fn all_denied(tier: Tier) -> ResolvedPolicy {
    let capabilities = Capability::ALL
        .into_iter()
        .map(|c| (c, PolicyState::Deny))
        .collect();
    ResolvedPolicy {
        tier,
        capabilities,
        paths: Vec::new(),
    }
}

fn with_allowed(mut policy: ResolvedPolicy, cap: Capability) -> ResolvedPolicy {
    policy.capabilities.insert(cap, PolicyState::Allow);
    policy
}

#[test]
fn container_net_allow_omits_private_network() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::Net),
        &ctx(),
    );
    assert!(
        !argv.contains(&"--private-network".to_string()),
        "net: allow must not isolate the network, got {argv:?}"
    );
}

#[test]
fn container_net_deny_adds_private_network() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(
        argv.contains(&"--private-network".to_string()),
        "net: deny must isolate the network, got {argv:?}"
    );
}

#[test]
fn container_nix_daemon_allow_binds_store_and_socket() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::NixDaemon),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind-ro=/nix/store".to_string()),
        "{argv:?}"
    );
    assert!(
        argv.contains(&"--bind=/nix/var/nix/daemon-socket/socket".to_string()),
        "{argv:?}"
    );
}

#[test]
fn container_nix_daemon_deny_binds_nothing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(!argv.iter().any(|a| a.contains("/nix/store")), "{argv:?}");
    assert!(
        !argv.iter().any(|a| a.contains("daemon-socket")),
        "{argv:?}"
    );
}

#[test]
fn container_repo_write_allow_binds_rw() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::RepoWrite),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind=/home/tester/dots".to_string()),
        "{argv:?}"
    );
    assert!(
        !argv.contains(&"--bind-ro=/home/tester/dots".to_string()),
        "{argv:?}"
    );
}

#[test]
fn container_repo_read_allow_binds_ro() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::RepoRead),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind-ro=/home/tester/dots".to_string()),
        "{argv:?}"
    );
    assert!(
        !argv.contains(&"--bind=/home/tester/dots".to_string()),
        "{argv:?}"
    );
}

#[test]
fn container_repo_deny_binds_nothing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(
        !argv.iter().any(|a| a.contains("/home/tester/dots")),
        "{argv:?}"
    );
}

#[test]
fn container_postgres_allow_binds_socket_dir() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::Postgres),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind=/run/postgresql".to_string()),
        "{argv:?}"
    );
}

#[test]
fn container_postgres_deny_binds_nothing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(!argv.iter().any(|a| a.contains("postgresql")), "{argv:?}");
}

#[test]
fn container_settings_ro_allow_binds_readonly() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::SettingsRo),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind-ro=/var/lib/dots/settings.nix".to_string()),
        "{argv:?}"
    );
}

#[test]
fn container_settings_ro_deny_binds_nothing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(!argv.iter().any(|a| a.contains("settings.nix")), "{argv:?}");
}

#[test]
fn container_kvm_allow_binds_device() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Container), Capability::Kvm),
        &ctx(),
    );
    assert!(argv.contains(&"--bind=/dev/kvm".to_string()), "{argv:?}");
}

#[test]
fn container_kvm_deny_binds_nothing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(!argv.iter().any(|a| a.contains("/dev/kvm")), "{argv:?}");
}

#[test]
fn container_grant_share_always_present() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(
        argv.contains(
            &"--bind=/run/user/1000/dots-sandbox/grants/nix-lint:/run/dots-grants".to_string()
        ),
        "grant share must be present even with nothing else granted, got {argv:?}"
    );
}

#[test]
fn vm_grant_share_always_present() {
    let argv = spawn_argv(&all_denied(Tier::Vm), &ctx());
    assert!(
        argv.contains(
            &"--bind=/run/user/1000/dots-sandbox/grants/nix-lint:/run/dots-grants".to_string()
        ),
        "grant share must be present even with nothing else granted, got {argv:?}"
    );
}

#[test]
fn vm_net_allow_adds_user_mode_networking() {
    let argv = spawn_argv(&with_allowed(all_denied(Tier::Vm), Capability::Net), &ctx());
    assert!(
        argv.contains(&"--network-user-mode".to_string()),
        "{argv:?}"
    );
}

#[test]
fn vm_net_deny_adds_no_network_flag() {
    let argv = spawn_argv(&all_denied(Tier::Vm), &ctx());
    assert!(
        !argv.contains(&"--network-user-mode".to_string()),
        "{argv:?}"
    );
    assert!(!argv.iter().any(|a| a.starts_with("--network")), "{argv:?}");
}

#[test]
fn vm_repo_write_allow_binds_rw_via_same_bind_flag() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Vm), Capability::RepoWrite),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind=/home/tester/dots".to_string()),
        "{argv:?}"
    );
}

#[test]
fn vm_settings_ro_allow_binds_readonly() {
    let argv = spawn_argv(
        &with_allowed(all_denied(Tier::Vm), Capability::SettingsRo),
        &ctx(),
    );
    assert!(
        argv.contains(&"--bind-ro=/var/lib/dots/settings.nix".to_string()),
        "{argv:?}"
    );
}

#[test]
fn extra_path_grant_allow_binds_at_resolved_mode() {
    let mut policy = all_denied(Tier::Container);
    policy.paths.push(ResolvedPathGrant {
        path: PathBuf::from("/home/tester/.cargo"),
        mode: PathMode::Rw,
        state: PolicyState::Allow,
    });
    let argv = spawn_argv(&policy, &ctx());
    assert!(
        argv.contains(&"--bind=/home/tester/.cargo".to_string()),
        "{argv:?}"
    );
}

#[test]
fn extra_path_grant_deny_binds_nothing() {
    let mut policy = all_denied(Tier::Container);
    policy.paths.push(ResolvedPathGrant {
        path: PathBuf::from("/home/tester/.ssh"),
        mode: PathMode::Rw,
        state: PolicyState::Deny,
    });
    let argv = spawn_argv(&policy, &ctx());
    assert!(!argv.iter().any(|a| a.contains(".ssh")), "{argv:?}");
}

#[test]
fn extra_path_grant_ask_binds_nothing() {
    let mut policy = all_denied(Tier::Container);
    policy.paths.push(ResolvedPathGrant {
        path: PathBuf::from("/home/tester/Downloads"),
        mode: PathMode::Ro,
        state: PolicyState::Ask,
    });
    let argv = spawn_argv(&policy, &ctx());
    assert!(
        !argv.iter().any(|a| a.contains("Downloads")),
        "an unanswered `ask` must never silently grant, got {argv:?}"
    );
}

#[test]
fn program_and_args_are_trailing() {
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    let tail = &argv[argv.len() - 3..];
    assert_eq!(
        tail,
        &["nix".to_string(), "flake".to_string(), "check".to_string()]
    );
}

#[test]
fn container_and_vm_tiers_produce_genuinely_different_command_lines() {
    // Same capabilities allowed on both tiers (only the ones both tiers can
    // honestly express), same LaunchCtx: the two argvs must still differ,
    // because the tool and its base flags differ per tier.
    let shared_caps: BTreeMap<Capability, PolicyState> = [
        (Capability::Net, PolicyState::Allow),
        (Capability::RepoWrite, PolicyState::Allow),
        (Capability::SettingsRo, PolicyState::Deny),
    ]
    .into_iter()
    .collect();

    let container = ResolvedPolicy {
        tier: Tier::Container,
        capabilities: shared_caps.clone(),
        paths: Vec::new(),
    };
    let vm = ResolvedPolicy {
        tier: Tier::Vm,
        capabilities: shared_caps,
        paths: Vec::new(),
    };

    let container_argv = spawn_argv(&container, &ctx());
    let vm_argv = spawn_argv(&vm, &ctx());

    assert_ne!(container_argv, vm_argv);
    assert_eq!(container_argv[0], "systemd-nspawn");
    assert_eq!(vm_argv[0], "systemd-vmspawn");
}
