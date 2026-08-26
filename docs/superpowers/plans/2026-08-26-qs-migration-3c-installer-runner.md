# Quickshell Migration 3c: Installer Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Execute the install from QML and delete `rust/installer-tui`.
**Architecture:** `install.rs`'s `plan()` becomes a pure `plan.js` building
the same ordered `WriteFile`/`Command` list; `Runner.qml` walks it one
`Process` at a time. Keeping the planner pure is the whole mitigation for
losing Rust on a path that partitions disks: the list is asserted first.
**Depends on:** plans 0, 3a and 3b.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- This is the disk-destroying path. Nothing here is verified by reading
  code; every step is verified in a VM.
- `RecoveryKey` capture takes the last non-empty stdout line and nothing
  else. That line is the LUKS recovery key; losing it locks the user out.
- Actions run in order, one at a time. No parallelism, no reordering.
- `Event` stays `StepStarted(i,total,title)`, `Log`, `RecoveryKey`,
  `Finished`, `Failed`.
- Steps shell out to disko, `nixos-facter`, `nixos-install`,
  `systemd-cryptenroll`, `nixos-enter`. Preserve argv exactly.

---

### Task 1: The action planner
**Files:** create `qml/installer/plan.js`; modify `tests/qml/tst_installer.qml`.
**Consumes** 3b's `config.js`. **Produces** `planFor(cfg)` -> the ordered
list, each `{kind, ...}` mirroring `install.rs`'s `Action`.

- [ ] **1** Capture the oracle: add a temporary `--dump-plan` to
      `installer-tui` printing `plan()`'s actions as JSON, run it with 3b's
      answers, save as a fixture
- [ ] **2** Write the test asserting `planFor` reproduces that list, in
      order, argv for argv. Run QtTest Expected: FAIL
- [ ] **3** Port `plan()` into `plan.js`. Run QtTest Expected: PASS
- [ ] **4** Assert the `RecoveryKey` step is present and is the only
      action with that capture mode. Run QtTest Expected: PASS, then
      revert the `--dump-plan` patch
- [ ] **5** `git commit -m "plan the install from the shell"`

### Task 2: The runner
**Files:** create `qml/installer/Runner.qml`, `Installing.qml`. **Consumes**
Task 1. **Produces** `run(actions)` emitting the `Event` shape.

- [ ] **1** Build `Runner.qml`: one `Process` per action, started only on
      the previous one's exit, non-zero exit raising `Failed`
- [ ] **2** Implement `WriteFile` with its mode, and `RecoveryKey` as
      last-non-empty-line
- [ ] **3** Build `Installing.qml`: step counter, scrolling log pane, and
      the recovery key shown unmissably
- [ ] **4** Point the runner at a harmless fake plan (`echo`, `false`)
      Expected: counter advances, `false` lands on Failed naming it
- [ ] **5** `git commit -m "run the install steps from the shell"`

### Task 3: Install a machine
**Files:** modify `tests/default.nix`.

- [ ] **1** Extend `tests/default.nix` to drive the QML flow to Confirm
      and run the install, as it drove the TUI
- [ ] **2** `nix run .#nix-smoke` Expected: the VM installs and reboots
      into the installed system
- [ ] **3** Read the captured log Expected: the recovery key printed once,
      and `/var/lib/dots/settings.nix` matches 3b's writer
- [ ] **4** Install to a spare physical disk Expected: it boots and TPM2
      auto-unlock works
- [ ] **5** `git commit -m "install a machine from the shell"`

### Task 4: Delete the crate
**Files:** delete `rust/installer-tui/`; modify `nix/iso.nix:32-46`,
`flake/packages.nix`, `flake/apps.nix:118`, `flake/devshell.nix`.

- [ ] **1** `git rm -r rust/installer-tui`, drop the `dots-installer`
      package and every reference above
- [ ] **2** `grep -rn 'installer-tui\|dots-installer' .` Expected: no hits
      outside `docs/`, and `ls rust` Expected: `settings-global` alone
- [ ] **3** `nix run .#nix-lint` and `nix run .#nix-smoke` Expected: both
      green, with no `cargo` line left except `settings-global`'s
- [ ] **4** `git commit -m "delete the installer TUI"`
