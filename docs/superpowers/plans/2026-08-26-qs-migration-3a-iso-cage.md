# Quickshell Migration 3a: Cage on the LiveISO Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Get `cage -s -- qs -p installer.qml` onto tty1 of the LiveISO and
prove it boots under OVMF, before a single installer screen is written.
**Architecture:** This plan is a gate, not a feature. It swaps the
`dots-installer` unit for a cage session running plan 0's placeholder
`installer.qml`, moves the smoke-test marker into QML, and answers the one
question the whole installer migration rests on. Quickshell 0.3, cage,
Mesa/llvmpipe, OVMF, swtpm.
**Depends on:** plan 0. Nothing in 3b or 3c may start until Task 3 passes.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The marker is renamed `DOTS_UI_READY` and emitted from QML's
  `Component.onCompleted`, not from `ExecStartPre`. The old marker fired
  before the binary ran and so proved less than it appeared to.
- The QML comes from the `quickshell-config` store path
  (`flake/packages.nix:71`), not from `/etc/dots`. The flake rides on the
  ISO so `nixos-install` can evaluate it, not so the shell can read it.
- `installer.qml` must not import `Quickshell.Hyprland`. Cage is a kiosk
  and there is no Hyprland on the ISO.
- The smoke test VM has no GPU. llvmpipe is the rendering path under test.

---

### Task 1: Put cage on the ISO
**Files:** modify `nix/system/iso.nix:63-100` (the `dots-installer` unit),
`nix/system/iso.nix:32-46` (`environment.systemPackages`).

- [ ] **1** Add `pkgs.cage`, `pkgs.quickshell` and `pkgs.mesa` to the ISO's
      package list
- [ ] **2** Replace the unit's `ExecStart` with
      `cage -s -- qs -p ${quickshell-config}/installer.qml`, dropping
      `ExecStartPre` and keeping `TTYPath=/dev/tty1`, `conflicts` on
      `getty@tty1` and `Restart=on-failure`
- [ ] **3** Set `WLR_RENDERER=pixman` and `WLR_BACKENDS=drm,libinput` in
      the unit's `Environment`, so a GPU-less VM does not fall back to a
      renderer that is not there
- [ ] **4** `nix run .#iso` Expected: it builds
- [ ] **5** `git commit -m "run a kiosk compositor on the install media"`

### Task 2: Move the readiness marker into QML
**Files:** modify `qml/installer.qml`, `tests/default.nix`.

- [ ] **1** In `installer.qml`, on `Component.onCompleted`, `Process`-write
      `DOTS_UI_READY` to `/dev/ttyS0` and `/dev/console`
- [ ] **2** Repoint `tests/default.nix:388`'s `wait_for_console_text` from
      `DOTS_TUI_READY` to `DOTS_UI_READY`
- [ ] **3** `grep -rn 'DOTS_TUI_READY' . --exclude-dir=.git`
      Expected: no hits
- [ ] **4** `nix run .#nix-lint` Expected: green
- [ ] **5** `git commit -m "let the shell announce itself to the test"`

### Task 3: The gate
**Files:** none. This task decides whether 3b and 3c happen at all.

- [ ] **1** `nix run .#nix-smoke` Expected: `DOTS_UI_READY` on the serial
      console within the test's timeout
- [ ] **2** If it passes, screenshot the VM
      (`driverInteractive`, then `machine.screenshot`) Expected: the
      placeholder panel is legible, not a black frame
- [ ] **3** If Step 1 fails, do NOT patch around it here. Capture the
      journal from the VM, record whether cage, wlroots or Qt is what
      failed, and stop. The spec's open risk has fired and the decision
      (virtio-gpu in the test VM, or keeping a TTY installer) is the
      user's to make, not this plan's
- [ ] **4** `git commit -m "assert the install media reaches its shell"`
