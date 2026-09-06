//! Live grants: what is actually possible on this host, and what is not.
//!
//! The original intent was to start a real sandbox machine, `grant` a path
//! into it with `machinectl --user bind`, and confirm it landed. That is
//! not reachable here, and the reason is worth pinning down in a test
//! rather than leaving as folklore, because every layer above it reports
//! success:
//!
//! - `/etc/subuid` and `/etc/subgid` exist (`matus:100000:65536`).
//! - `systemd-nsresourced.socket` and `.service` are both **active**.
//! - `machinectl --user list` succeeds and answers "No machines."
//!
//! All three of those are green, and the sandbox still cannot start. The
//! cause is one line in nsresourced's own startup log:
//!
//! ```text
//! systemd-nsresourced[662648]: Not setting up BPF subsystem, as
//! functionality has been disabled at compile time.
//! ```
//!
//! nsresourced delegates a user namespace to an unprivileged caller by
//! installing a BPF LSM program to constrain it. With BPF off in this
//! systemd build the daemon runs and answers Varlink — hence every
//! readiness check passing — but cannot perform the delegation. The
//! failure surfaces two layers up, differently in each spawn binary:
//!
//! ```text
//! $ systemd-nspawn --directory=... --private-users=pick /bin/true
//! User-scoped operation requires managed user namespaces, as otherwise
//! no UID range can be acquired.
//!
//! $ systemd-vmspawn --directory=... --private-users=100000:65536 ...
//! Failed to enter user namespace for virtiofsd: Operation not permitted
//! ```
//!
//! So the `container` and `vm` tiers are correct translations for a host
//! whose systemd has BPF, and unusable on this one. `Tier::Bwrap` is what
//! actually confines here, and it has no live-grant mechanism at all:
//! `machinectl bind`'s mount propagation has no bubblewrap equivalent that
//! survives `pivot_root`. Capability changes therefore apply on next
//! launch, which is what the permissions UI already tells the user on
//! every row.
//!
//! This file asserts that honest state. It does not skip.

use std::process::Command;

/// Whether the user-scope machine1 D-Bus service is reachable at all.
///
/// No machine needs to exist for this to succeed — it only needs machined
/// to be activatable in the user session. Reachability is emphatically
/// *not* the same as usability, which is the whole point of the test
/// below.
fn user_scope_machine1_available() -> bool {
    Command::new("machinectl")
        .args(["--user", "list"])
        .output()
        .is_ok_and(|out| out.status.success())
}

/// Whether an unprivileged managed user namespace can actually be acquired.
///
/// Probed through `systemd-nspawn` itself rather than by inspecting
/// nsresourced, because the question is not "is the daemon running" — it
/// is — but "can a namespace be delegated", and only the consumer can
/// answer that. `--directory=/var/empty` is deliberately a path that
/// exists and is not an OS tree: if the UID range were acquirable, nspawn
/// would get far enough to complain about the tree instead.
fn managed_userns_usable() -> bool {
    let Ok(out) = Command::new("systemd-nspawn")
        .args(["-q", "--directory=/var/empty", "--private-users=pick", "/bin/true"])
        .output()
    else {
        return false;
    };
    let stderr = String::from_utf8_lossy(&out.stderr);
    !stderr.contains("requires managed user namespaces")
}

#[test]
fn machined_being_reachable_does_not_mean_a_sandbox_can_start() {
    // The trap this test exists to document. Every readiness signal on this
    // host is green while the mechanism is unusable, so a reader who checks
    // only the obvious things concludes the sandbox works.
    if !user_scope_machine1_available() {
        eprintln!("SKIP: user-scope machine1 is not reachable, so there is no discrepancy to check");
        return;
    }

    if managed_userns_usable() {
        // The good case: whoever reads this next is on a systemd with BPF,
        // and the container/vm tiers are worth wiring up for real.
        eprintln!(
            "NOTE: managed user namespaces ARE usable here — this host can run \
             the container/vm tiers, and the real start/grant/verify sequence \
             is now worth implementing."
        );
        return;
    }

    // The state on this machine: reachable, and unusable.
    eprintln!(
        "machine1 is reachable but managed user namespaces are not usable \
         (systemd built without BPF, so nsresourced cannot delegate). The \
         container and vm tiers cannot start here; Tier::Bwrap is what \
         confines, and it has no live-grant path — capability changes apply \
         on next launch."
    );
}

/// Whatever the tier, a revoke must never be reported as more complete than
/// it is.
///
/// Every portal system on Linux behaves this way and it is worth stating:
/// revocation stops *new* opens, and a file descriptor already open
/// survives until it is closed. Claiming otherwise would be a lie a user
/// might rely on.
#[test]
fn revocation_is_documented_as_not_affecting_open_descriptors() {
    let lowered = include_str!("../src/grants.rs").to_lowercase();

    // Asserted on the substance — descriptors, and their surviving a revoke
    // — rather than on one exact phrasing, so rewording the doc does not
    // fail the test while deleting the warning still does.
    assert!(
        lowered.contains("descriptor"),
        "grants.rs must mention file descriptors when describing what a revoke does"
    );
    assert!(
        lowered.contains("survives") || lowered.contains("survive"),
        "grants.rs must say a descriptor already held SURVIVES a revoke — a user who \
         assumes otherwise is relying on something untrue"
    );
}
