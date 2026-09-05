//! The pure seam: turning a [`ResolvedPolicy`] into the argv of either
//! `systemd-nspawn` (the `container` tier) or `systemd-vmspawn` (the `vm`
//! tier). [`spawn_argv`] does no filesystem access, no environment reads
//! and no clock reads — every path, name and argument it needs arrives
//! through [`LaunchCtx`] — so the whole capability-to-command-line
//! translation is testable without a namespace, a VM, or root. Nothing in
//! this module spawns a process; that is a later task's job, once the
//! privilege question this crate's brief flags as still-being-probed is
//! settled.
//!
//! Every flag emitted here was checked against `man systemd-nspawn` and
//! `man systemd-vmspawn` on the machine this crate was written on
//! (systemd 261). Where the two man pages disagreed with a first guess,
//! the man page won; where a capability had no clean expression on a
//! tier, [`crate::policy::check_tier_compatibility`]-style validation
//! rejects it during policy resolution instead of this function silently
//! emitting a flag that will not work — see the `postgres`-under-`vm`
//! case, which is exactly that situation.

use std::path::PathBuf;

use crate::policy::{Capability, PathMode, PolicyState, ResolvedPolicy, Tier};

/// Absolute host paths and names baked into the argv translation. These
/// are not read from disk or environment inside this module — they are
/// well-known Nix/systemd locations that hold regardless of which user or
/// machine is asking (the nix daemon socket path, the postgres socket
/// directory, `/dev/kvm`), so a literal here is a documented constant, not
/// a shortcut around the "no filesystem access" rule.
mod fixed_paths {
    /// The nix store itself, bound read-only into `nix-daemon`-capable
    /// containers so the sandboxed process can resolve store paths.
    pub const NIX_STORE: &str = "/nix/store";
    /// The multi-user nix daemon's well-known socket path.
    pub const NIX_DAEMON_SOCKET: &str = "/nix/var/nix/daemon-socket/socket";
    /// Where postgres's peer-authenticated unix socket lives.
    pub const POSTGRES_SOCKET_DIR: &str = "/run/postgresql";
    /// The root-owned machine-identity settings file (distinct from the
    /// per-user `~/.config/dots-sandbox/overrides.json` this crate itself
    /// reads: that one is never bound into a sandbox, since it is a sandbox
    /// policy file, not application settings).
    pub const SETTINGS_FILE: &str = "/var/lib/dots/settings.nix";
    /// The KVM device node, bound in only for a `container`-tier app that
    /// itself needs to accelerate a nested VM; not meaningful for a `vm`-
    /// tier app, which gets its own acceleration via `--kvm=yes`.
    pub const KVM_DEVICE: &str = "/dev/kvm";
    /// Fixed in-sandbox mount point for the grant-share directory, present
    /// in every launch of either tier so the broker can add a bind under
    /// it on the host and have the sandbox see it appear, even before any
    /// path has actually been granted.
    pub const GRANT_SHARE_MOUNT: &str = "/run/dots-grants";
}

/// Everything [`spawn_argv`] needs from the outside world, gathered by the
/// caller ahead of time so this module never has to look anything up
/// itself. Constructing one of these is where a later launcher task reads
/// `$HOME`, `$XDG_RUNTIME_DIR` and the rest of the environment; by the time
/// a `LaunchCtx` exists, none of that is needed again.
#[derive(Debug, Clone)]
pub struct LaunchCtx {
    /// The invoking user's home directory. Not consulted by `spawn_argv`
    /// today — every path capability already arrives pre-expanded on
    /// [`ResolvedPolicy`] — but kept here because a future capability
    /// (binding a scratch `$HOME` into the sandbox, say) will need it, and
    /// because the brief that defines this struct names it explicitly as
    /// something the outside world must hand in rather than this module
    /// discover.
    pub home_dir: PathBuf,
    /// `$XDG_RUNTIME_DIR`. Reserved for the session-state layer
    /// (`$XDG_RUNTIME_DIR/dots-sandbox/`) a later task builds; this crate
    /// only leaves room for it.
    pub runtime_dir: PathBuf,
    /// The dots repo checkout root, bound in (rw or ro) when `repo-write`
    /// or `repo-read` resolves to `allow`.
    pub repo_root: PathBuf,
    /// The host directory the live-grant broker adds binds under. Always
    /// mounted at [`fixed_paths::GRANT_SHARE_MOUNT`] in both tiers, even
    /// before any grant exists.
    pub grant_share_dir: PathBuf,
    /// The `--machine=` name for this launch (`systemd-nspawn` and
    /// `systemd-vmspawn` share the flag and its semantics).
    pub machine_name: String,
    /// `container` tier only: the OS tree passed to `--directory=`. Built
    /// by a later Nix task; `spawn_argv` only ever reads this path back
    /// out into a flag, never opens it.
    pub container_rootfs: PathBuf,
    /// `vm` tier only: the kernel image passed to `--linux=` for direct
    /// kernel boot. `systemd-vmspawn` needs no accompanying `--directory=`
    /// or `--image=` for this crate's launches — see the module doc
    /// comment on the tier's confirmed flag set — so no such field exists
    /// here; adding one back is a decision for whoever builds the actual
    /// VM image in the Nix-side task.
    pub vm_kernel: PathBuf,
    /// `vm` tier only: an explicit path to the firmware descriptor (an
    /// OVMF `..._CODE.fd`-style file), required because
    /// `systemd-vmspawn --firmware=list` prints nothing on this machine —
    /// NixOS does not populate the firmware descriptor JSONs vmspawn's
    /// `auto`/`uefi` discovery relies on — so the launcher must resolve
    /// and pass an explicit path rather than relying on `--firmware=uefi`.
    pub vm_firmware: PathBuf,
    /// The program to run inside the sandbox.
    pub program: String,
    /// Arguments to `program`.
    pub args: Vec<String>,
}

/// Turns a resolved policy into the full argv for launching `resolved`'s
/// tier. Element 0 is the tool name (`systemd-nspawn` or `systemd-vmspawn`
/// with no path — `PATH` resolution is the caller's concern); the trailing
/// elements are `ctx.program` followed by `ctx.args`, unmodified.
#[must_use]
pub fn spawn_argv(resolved: &ResolvedPolicy, ctx: &LaunchCtx) -> Vec<String> {
    match resolved.tier {
        Tier::Container => container_argv(resolved, ctx),
        Tier::Vm => vm_argv(resolved, ctx),
    }
}

/// Looks up a capability's resolved state, treating an absent capability
/// (one the policy never mentioned at all) the same as an explicit `deny`
/// — the safe default for a sandbox, where the absence of a grant must
/// never read as a grant.
fn state_of(resolved: &ResolvedPolicy, cap: Capability) -> PolicyState {
    resolved
        .capabilities
        .get(&cap)
        .copied()
        .unwrap_or(PolicyState::Deny)
}

/// Emits the `--bind=`/`--bind-ro=` pair shared by `repo-write` and
/// `repo-read`: write access implies read access, so a policy granting
/// both (unusual, but not rejected — see the merge rules) is honored as
/// read-write rather than emitting two conflicting bind flags for the same
/// path.
fn push_repo_bind(argv: &mut Vec<String>, resolved: &ResolvedPolicy, repo_root: &std::path::Path) {
    if state_of(resolved, Capability::RepoWrite) == PolicyState::Allow {
        argv.push(format!("--bind={}", repo_root.display()));
    } else if state_of(resolved, Capability::RepoRead) == PolicyState::Allow {
        argv.push(format!("--bind-ro={}", repo_root.display()));
    }
}

/// Emits one `--bind=`/`--bind-ro=` flag per `allow`-state entry in
/// `resolved.paths`. `deny` and `ask` both emit nothing: `ask` reaching
/// this function unresolved means no prompt has answered it yet, and the
/// safe default is silence, not a guess.
fn push_extra_paths(argv: &mut Vec<String>, resolved: &ResolvedPolicy) {
    for grant in &resolved.paths {
        if grant.state != PolicyState::Allow {
            continue;
        }
        match grant.mode {
            PathMode::Rw => argv.push(format!("--bind={}", grant.path.display())),
            PathMode::Ro => argv.push(format!("--bind-ro={}", grant.path.display())),
        }
    }
}

/// Builds a `systemd-nspawn` command line for the `container` tier: the
/// nix-heavy apps that need `/nix/store` and the nix daemon socket as
/// ordinary bind mounts.
fn container_argv(resolved: &ResolvedPolicy, ctx: &LaunchCtx) -> Vec<String> {
    let mut argv = vec!["systemd-nspawn".to_string()];

    argv.push(format!("--directory={}", ctx.container_rootfs.display()));
    // `--ephemeral`: the base row's "ephemeral root" — every launch starts
    // from a fresh, disposable snapshot of the OS tree.
    argv.push("--ephemeral".to_string());
    // `managed` is the mode systemd-nspawn itself selects by default when
    // invoked unprivileged (uid 1000, the case this crate's brief already
    // established for this machine), delegating UID range allocation to
    // systemd-nsresourced. It is named explicitly here rather than left to
    // the default so the choice is visible in the emitted argv and does
    // not silently change if some future invocation runs privileged.
    argv.push("--private-users=managed".to_string());
    argv.push(format!("--machine={}", ctx.machine_name));
    // No journal link: the base row's "no journal link". A sandboxed app's
    // journal has no reason to appear in the host's.
    argv.push("--link-journal=no".to_string());

    // `net`: nspawn shares the host network namespace by default: absence
    // of `--private-network` means "networked". So `deny`/`ask` must add
    // the isolating flag, and only `allow` may omit it.
    if state_of(resolved, Capability::Net) != PolicyState::Allow {
        argv.push("--private-network".to_string());
    }

    if state_of(resolved, Capability::NixDaemon) == PolicyState::Allow {
        argv.push(format!("--bind-ro={}", fixed_paths::NIX_STORE));
        argv.push(format!("--bind={}", fixed_paths::NIX_DAEMON_SOCKET));
    }

    push_repo_bind(&mut argv, resolved, &ctx.repo_root);

    if state_of(resolved, Capability::Postgres) == PolicyState::Allow {
        argv.push(format!("--bind={}", fixed_paths::POSTGRES_SOCKET_DIR));
    }
    if state_of(resolved, Capability::SettingsRo) == PolicyState::Allow {
        argv.push(format!("--bind-ro={}", fixed_paths::SETTINGS_FILE));
    }
    if state_of(resolved, Capability::Kvm) == PolicyState::Allow {
        argv.push(format!("--bind={}", fixed_paths::KVM_DEVICE));
    }

    // The grant share: always present, in both tiers, even with nothing
    // granted under it yet.
    argv.push(format!(
        "--bind={}:{}",
        ctx.grant_share_dir.display(),
        fixed_paths::GRANT_SHARE_MOUNT
    ));

    push_extra_paths(&mut argv, resolved);

    argv.push(ctx.program.clone());
    argv.extend(ctx.args.iter().cloned());
    argv
}

/// Builds a `systemd-vmspawn` command line for the `vm` tier: GUI apps and
/// light CLI apps, run under KVM acceleration with a direct kernel boot.
fn vm_argv(resolved: &ResolvedPolicy, ctx: &LaunchCtx) -> Vec<String> {
    let mut argv = vec!["systemd-vmspawn".to_string()];

    // The base row: KVM acceleration insisted on (not left to `auto`, so a
    // host without it fails loudly instead of silently falling back to
    // slow emulation) plus a direct kernel boot.
    argv.push("--kvm=yes".to_string());
    argv.push(format!("--linux={}", ctx.vm_kernel.display()));
    // Explicit firmware path — see the doc comment on `LaunchCtx::vm_firmware`
    // for why `--firmware=uefi`'s auto-discovery cannot be relied on here.
    argv.push(format!("--firmware={}", ctx.vm_firmware.display()));
    argv.push(format!("--machine={}", ctx.machine_name));

    // `net`: unlike nspawn, vmspawn hands the guest no network device at
    // all unless one is asked for, so `allow` is the one case that adds a
    // flag. `--network-tap` needs root (this session has none), so `allow`
    // maps to `--network-user-mode`, the unprivileged SLIRP-style option.
    if state_of(resolved, Capability::Net) == PolicyState::Allow {
        argv.push("--network-user-mode".to_string());
    }

    push_repo_bind(&mut argv, resolved, &ctx.repo_root);

    if state_of(resolved, Capability::SettingsRo) == PolicyState::Allow {
        argv.push(format!("--bind-ro={}", fixed_paths::SETTINGS_FILE));
    }
    // `nix-daemon`, `postgres` and `kvm` do not appear here: policy
    // resolution already refuses to resolve any of them to `allow` on the
    // `vm` tier (see `crate::policy::check_tier_compatibility`), so a
    // `ResolvedPolicy` reaching this function can never carry one.

    argv.push(format!(
        "--bind={}:{}",
        ctx.grant_share_dir.display(),
        fixed_paths::GRANT_SHARE_MOUNT
    ));

    push_extra_paths(&mut argv, resolved);

    argv.push(ctx.program.clone());
    argv.extend(ctx.args.iter().cloned());
    argv
}
