//! The one test that would prove a live grant actually works end to end:
//! start a real sandbox machine, `grant` a path into it via `machinectl
//! --user bind`, and confirm it landed.
//!
//! It cannot run to completion on this machine. `systemd-nspawn`'s
//! unprivileged user-scope operation depends on
//! `systemd-nsresourced.service`, which is not enabled here yet —
//! enabling it needs a NixOS rebuild nobody has authorised for this task.
//! Confirmed directly against this machine, not assumed:
//!
//! ```text
//! $ systemctl list-unit-files 'systemd-nsresourced*'
//! 0 unit files listed.
//! $ machinectl --user list
//! Could not get machines: Could not activate remote peer
//! 'org.freedesktop.machine1': activation request failed: unknown unit
//! ```
//!
//! So rather than fail (and block CI on an environment gap that a
//! different, already-planned task closes), this test checks for that
//! specific unavailability and skips with a clear message. Real
//! end-to-end proof belongs in the NixOS VM test
//! (`checks.x86_64-linux.iso-boot` and friends), which boots a real
//! image with the module enabled — not here.
use std::process::Command;

/// `machinectl --user list` is the cheapest possible probe for "is the
/// user-scope machine1 D-Bus service reachable at all" — no machine
/// needs to exist for this to succeed; it only needs machined itself to
/// be activatable in the user session.
fn user_scope_machine1_available() -> bool {
    Command::new("machinectl")
        .args(["--user", "list"])
        .output()
        .is_ok_and(|out| out.status.success())
}

#[test]
fn grant_lands_on_a_freshly_started_machine() {
    if !user_scope_machine1_available() {
        eprintln!(
            "SKIP: user-scope machine1 is not reachable on this machine \
             (systemd-nsresourced is not enabled yet; see this file's \
             module doc comment). Real end-to-end proof is the NixOS VM \
             test, not this one."
        );
        return;
    }

    // Reachable here means a future environment where nsresourced is
    // enabled; this task does not implement the "start a container, then
    // grant into it" orchestration itself (that lives in `launch::run`
    // plus a real `spawn_argv`, neither fully wired up against each
    // other yet — see this task's report). Once both exist, replace this
    // branch with the real start-machine/grant/verify sequence instead of
    // this placeholder assertion.
    panic!(
        "user-scope machine1 is reachable on this machine, which this test \
         did not expect when it was written — implement the real \
         start/grant/verify sequence now that the environment supports it, \
         rather than leaving this placeholder in place."
    );
}
