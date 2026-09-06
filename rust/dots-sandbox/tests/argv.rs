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
        wayland_display: "wayland-1".to_string(),
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
fn container_net_deny_grants_no_network_device() {
    // The container tier runs on vmspawn now (nspawn's unprivileged managed
    // mode cannot start on nixpkgs-built systemd — see `container_argv`), and
    // the two tools are inverses here. nspawn shared the host network by
    // default, so isolation meant *adding* `--private-network`. vmspawn hands
    // the guest no network device at all unless asked, so denial means
    // *omitting* the flag. Asserting on the old flag would now pass
    // vacuously — it can never appear — which is why this checks the
    // grant-side flag is absent instead.
    let argv = spawn_argv(&all_denied(Tier::Container), &ctx());
    assert!(
        !argv.contains(&"--network-user-mode".to_string()),
        "net: deny must not grant a network device, got {argv:?}"
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
    // Assert on the bind flags, not on any argument merely *containing* the
    // paths. The rootfs handed to `--image=` is itself a store path, so a
    // substring check for "/nix/store" now matches the tier's own scaffolding
    // and fails on correct output — the same trap the lockdown prose check
    // fell into in tests/report.rs.
    assert!(
        !argv.contains(&"--bind-ro=/nix/store".to_string()),
        "nix-daemon: deny must not bind the store, got {argv:?}"
    );
    assert!(
        !argv
            .iter()
            .any(|a| a.starts_with("--bind=") && a.contains("daemon-socket")),
        "nix-daemon: deny must not bind the daemon socket, got {argv:?}"
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
    // Both tiers spawn through vmspawn now — nspawn's unprivileged managed
    // mode cannot start on nixpkgs-built systemd, so the container tier keeps
    // its capability profile and changes only the mechanism under it.
    assert_eq!(container_argv[0], "systemd-vmspawn");
    assert_eq!(vm_argv[0], "systemd-vmspawn");
    // Sharing a tool must not collapse the tiers into the same launch. The
    // container tier boots a root image; the vm tier does not. Without this
    // the assert_ne above could be satisfied by some incidental ordering
    // difference rather than by the tiers actually meaning different things.
    assert!(
        container_argv.iter().any(|a| a.starts_with("--image=")),
        "the container tier must boot its root image, got {container_argv:?}"
    );
    assert!(
        !vm_argv.iter().any(|a| a.starts_with("--image=")),
        "the vm tier takes no root image, got {vm_argv:?}"
    );
}

// --- the bwrap tier ------------------------------------------------------
//
// The only tier that confines on this host. `container` and `vm` both route
// through systemd-nsresourced, whose namespace delegation installs a BPF LSM
// program, and this systemd is built without BPF — see tests/live_grant.rs
// for the measurements behind that claim.

#[test]
fn bwrap_denies_everything_it_was_not_asked_to_grant() {
    // The safety property the tier is built around: a capability this
    // translation forgets can only ever produce an app that cannot do
    // something, never one that can do something it was not granted.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx()).join(" ");

    assert!(argv.starts_with("bwrap "), "must invoke bwrap, got: {argv}");
    assert!(
        argv.contains("--unshare-net"),
        "no net capability means no network namespace"
    );
    assert!(!argv.contains("/run/postgresql"), "postgres was denied");
    assert!(!argv.contains("/dev/kvm"), "kvm was denied");
    assert!(
        !argv.contains("daemon-socket"),
        "nix-daemon was denied: {argv}"
    );
    assert!(
        !argv.contains("--bind /home/tester/dots"),
        "neither repo capability was granted: {argv}"
    );
}

#[test]
fn bwrap_replaces_home_with_a_tmpfs_rather_than_leaving_it_unbound() {
    // The distinction between confined and not. An unbound path is still
    // visible through the mount namespace the sandbox inherits; only
    // replacing it makes ~/.ssh unreachable. Verified against a planted
    // canary on the real machine, and pinned here so it stays true.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx()).join(" ");

    assert!(
        argv.contains("--tmpfs /home/tester"),
        "home must be replaced, not merely left unmentioned: {argv}"
    );
}

#[test]
fn bwrap_always_binds_the_store_read_only() {
    // Not a capability: every binary here is a store path, so a sandbox
    // without it cannot execve at all. It is world-readable and immutable,
    // so it holds nothing a policy would withhold — but it must never be
    // writable.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx()).join(" ");

    assert!(argv.contains("--ro-bind /nix/store /nix/store"));
    assert!(
        !argv.contains("--bind /nix/store /nix/store"),
        "the store must never be writable: {argv}"
    );
}

#[test]
fn bwrap_never_lets_a_setuid_binary_gain_privilege() {
    // --unshare-user is what makes handing over a whole read-only
    // /nix/store safe: nothing inside can elevate through setuid.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx()).join(" ");

    assert!(argv.contains("--unshare-user"));
}

#[test]
fn bwrap_dies_with_its_parent() {
    // Without this, killing the launcher orphans the sandbox — the failure
    // `nix run .#<app>` must not have, and the one signal forwarding cannot
    // cover, because SIGKILL is uncatchable.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx()).join(" ");

    assert!(argv.contains("--die-with-parent"));
}

#[test]
fn bwrap_net_allow_drops_the_namespace_and_adds_resolver_config() {
    let policy = with_allowed(all_denied(Tier::Bwrap), Capability::Net);
    let argv = spawn_argv(&policy, &ctx()).join(" ");

    assert!(
        !argv.contains("--unshare-net"),
        "granted net must share the host stack"
    );
    assert!(
        argv.contains("/etc/resolv.conf"),
        "a shared network stack with no resolver config resolves nothing: {argv}"
    );
}

#[test]
fn bwrap_repo_write_implies_read_and_is_the_writable_bind() {
    let write = spawn_argv(
        &with_allowed(all_denied(Tier::Bwrap), Capability::RepoWrite),
        &ctx(),
    )
    .join(" ");
    assert!(write.contains("--bind /home/tester/dots /home/tester/dots"));

    let read = spawn_argv(
        &with_allowed(all_denied(Tier::Bwrap), Capability::RepoRead),
        &ctx(),
    )
    .join(" ");
    assert!(read.contains("--ro-bind /home/tester/dots /home/tester/dots"));
    assert!(
        !read.contains("--bind /home/tester/dots /home/tester/dots"),
        "repo-read alone must not grant write: {read}"
    );
}

#[test]
fn bwrap_kvm_uses_dev_bind_not_a_plain_bind() {
    // A device node bound with --bind loses its device-ness; /dev/kvm needs
    // --dev-bind to be usable inside.
    let policy = with_allowed(all_denied(Tier::Bwrap), Capability::Kvm);
    let argv = spawn_argv(&policy, &ctx()).join(" ");

    assert!(argv.contains("--dev-bind /dev/kvm /dev/kvm"), "got: {argv}");
}

#[test]
fn bwrap_puts_the_program_last_with_its_arguments() {
    // Everything before the program is a bwrap flag; anything leaking past
    // it would be handed to the app instead of to bwrap.
    let argv = spawn_argv(&all_denied(Tier::Bwrap), &ctx());
    let tail: Vec<&str> = argv.iter().rev().take(3).map(String::as_str).collect();

    assert_eq!(tail, vec!["check", "flake", "nix"]);
}
