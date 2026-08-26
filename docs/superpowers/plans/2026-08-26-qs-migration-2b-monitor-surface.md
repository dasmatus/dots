# Quickshell Migration 2b: Monitor Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Move monitor hotplug into the shell process, give the override
editor a drag-to-arrange canvas, and delete `rust/hyprmon`.
**Architecture:** `watch.rs` is replaced rather than ported. Instead of
reading Hyprland's socket2, a `Connections` block on `Quickshell.Hyprland`
re-runs 2a's `planFor` when the monitor list changes, and applies each spec
through one `hyprctl keyword monitor` call. Quickshell 0.3, Qt 6.11.
**Depends on:** plans 0 and 2a. 2a's parity test is the only evidence the
crate can be deleted safely, so do not start before it is green.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The watcher lives in `shell.qml`'s tree, so it exists only inside a
  graphical session. That is a deliberate narrowing from the systemd user
  service, which started slightly earlier. Do not re-add a unit for it.
- Overrides remain a separate document from the Nix-managed rules.
- Apply is one `hyprctl keyword monitor` call per spec, not a batch. A
  failing output must not take the others down with it.

---

### Task 1: The hotplug watcher
**Files:** create `qml/monitors/Watcher.qml`; modify `qml/shell.qml`.
**Consumes** 2a's `planFor`, `applyOverrides`, `render`.
**Produces** `apply()`, re-running the plan against the live monitor list.

- [ ] **1** Write `Watcher.qml`: read rules and overrides through
      `FileView` + `JsonAdapter`, and `Quickshell.Hyprland`'s monitor list
- [ ] **2** Wire a `Connections` block so a monitor change calls `apply()`
- [ ] **3** Apply each rendered spec with its own `Process`
- [ ] **4** With `hyprmon.service` still running, stop it
      (`systemctl --user stop hyprmon`), then unplug and replug a monitor
      Expected: the layout still comes back, now from the shell
- [ ] **5** Check `qs` logs Expected: one `hyprctl` call per output, no
      errors
- [ ] **6** `git commit -m "watch for monitor hotplug in the shell"`

### Task 2: The arrange surface
**Files:** create `qml/monitors/Arrange.qml`; modify `qml/shell.qml`,
`nix/home/keybinds.nix`.
**Produces** a canvas of draggable monitor rectangles writing
`overrides.json`, replacing `tui.rs`'s `hyprmon override`.

- [ ] **1** Draw one rectangle per monitor, scaled to fit, labelled with
      the name and resolution
- [ ] **2** Make them draggable, snapping edges to neighbours
- [ ] **3** Write the resulting positions to `overrides.json` on confirm
- [ ] **4** Bind it to a keybind in `keybinds.nix`
- [ ] **5** Drag a monitor and confirm Expected: `overrides.json` gains the
      new position and Task 1's watcher applies it immediately
- [ ] **6** Press escape mid-drag Expected: `overrides.json` unchanged
- [ ] **7** `git commit -m "arrange monitors by dragging them"`

### Task 3: Delete the crate
**Files:** delete `rust/hyprmon/`, `nix/home/hyprmon.nix`; modify
`flake/packages.nix:47-63`, `flake/apps.nix:123`, `flake/nixos.nix:28`,
`nix/home/default.nix:38`, `nix/home/settings-menu.nix`.

- [ ] **1** Re-run 2a's parity test Expected: PASS. If it fails, stop
- [ ] **2** `git rm -r rust/hyprmon nix/home/hyprmon.nix` and strip every
      reference above
- [ ] **3** Rename the rules file to `~/.config/dots-shell/monitors.json`
      and repoint `Watcher.qml` and `Arrange.qml`
- [ ] **4** `grep -rn 'hyprmon' . --exclude-dir=.git` Expected: no hits
      outside `docs/`
- [ ] **5** `nix run .#nix-lint` Expected: green
- [ ] **6** `systemctl --user list-units | grep hyprmon` Expected: nothing
- [ ] **7** Rebuild, log out and back in, then hotplug a monitor
      Expected: the layout applies with no Rust binary present
- [ ] **8** `git commit -m "delete the monitor TUI"`
