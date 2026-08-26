# Quickshell Migration 3b: Installer Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Rebuild `installer-tui`'s 16-screen flow as QML, collecting the
same answers into the same `settings.nix`, without yet running an install.
**Architecture:** `app.rs`'s state machine becomes a `StackView` over
`qml/installer/`; answers accumulate in one `InstallConfig` that
`config.js` renders to `settings.nix`. Nothing destructive runs here.
**Depends on:** plans 0 and 3a. 3a's gate must be green.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The 16 screens, in `app.rs` order: Welcome, Network, WifiPassword,
  WifiConnecting, DiskSelect, Hostname, Username, GitName, GitEmail, Ai,
  UserPassword, UserPasswordConfirm, Confirm, Installing, Done, Failed.
- DiskSelect is skipped when autodetection picks a single disk
  unambiguously. Preserve that; it is the common path.
- Ai defaults to all toggles on and maps to `settings.ai*`, which
  `nix/modules/dots.nix` bridges to `options.dots.ai.*`.
- Keyboard must reach every control; the ISO may have no pointer.
- Validators come from `settings-global`'s `validate_hostname`,
  `validate_git_name`, `validate_git_email`. Do not invent new ones.

---

### Task 1: The config document and its writer
**Files:** create `qml/installer/config.js`, `tests/qml/tst_installer.qml`.
**Produces** `defaults()` -> the answer object; `settingsNix(cfg)` -> the
`settings.nix` text, matching `installer-tui/src/config.rs::settings_nix`.

- [ ] **1** Capture the oracle: run the current installer to Confirm with
      known answers, save the `settings.nix` it would write
- [ ] **2** Assert `settingsNix` reproduces it byte for byte in
      `tst_installer.qml`. Run QtTest Expected: FAIL
- [ ] **3** Port `config.rs`'s writer into `config.js`. Run QtTest
      Expected: PASS
- [ ] **4** `git commit -m "write the install answers from the shell"`

### Task 2: The text-entry screens
**Files:** create `qml/installer/Welcome.qml`, `Hostname.qml`,
`Username.qml`, `GitName.qml`, `GitEmail.qml`, `UserPassword.qml`,
`UserPasswordConfirm.qml`, `Ai.qml`; modify `qml/installer.qml`.
**Consumes** Task 1's `defaults()`. **Produces** a `StackView` flow.

- [ ] **1** Build the `StackView` and the eight screens, each writing one
      field and reachable by keyboard alone
- [ ] **2** Port the three validators; show failures inline and block
      advancing while invalid
- [ ] **3** Add `_data()` rows to `tst_installer.qml` per validator, from
      `settings-global/tests/settings.rs`. Run QtTest Expected: PASS
- [ ] **4** `qs -p result/installer.qml` and walk the flow with the
      keyboard only Expected: every field reachable, escape goes back
- [ ] **5** `git commit -m "collect the install answers on screen"`

### Task 3: Network and disks
**Files:** create `qml/installer/Network.qml`, `WifiPassword.qml`,
`WifiConnecting.qml`, `DiskSelect.qml`, `qml/installer/disks.js`.
**Produces** `parseLsblk(json)` and `autodetectDisk(disks)`, ported from
`disks.rs`; `nmcli` scanning and connect through `Process`.

- [ ] **1** Add `_data()` rows from `installer-tui/tests/disks.rs` over the
      checked-in `tests/fixtures/lsblk.json`. Run QtTest Expected: FAIL
- [ ] **2** Port `disks.rs`'s parse and autodetect into `disks.js`. Run
      QtTest Expected: PASS, including the skip-DiskSelect case
- [ ] **3** Build the four screens; drive `nmcli` through `Process`
- [ ] **4** In a VM with two disks Expected: DiskSelect appears; with one,
      it is skipped
- [ ] **5** `git commit -m "pick the disk and the network on screen"`

### Task 4: Confirm, Done and Failed
**Files:** create `qml/installer/Confirm.qml`, `Done.qml`, `Failed.qml`.
**Produces** the three terminal screens. Confirm shows every answer and
the target disk; nothing is executed until plan 3c.

- [ ] **1** Build the three screens; Confirm renders `settingsNix(cfg)`
- [ ] **2** Walk the flow in a VM Expected: Confirm shows the answers
      given, autodetect agrees with `lsblk`, `nix run .#nix-lint` green
- [ ] **3** `git commit -m "confirm the install answers before writing"`
