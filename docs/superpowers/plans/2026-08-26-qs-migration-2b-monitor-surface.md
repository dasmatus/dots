# Quickshell Migration 2b: Monitor Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Move monitor hotplug into the shell process, give the override
editor a drag-to-arrange canvas, and delete `rust/hyprmon`.
**Architecture:** `watch.rs` is replaced, not ported: a `Connections` block
on `Quickshell.Hyprland` re-runs 2a's `planFor` when the monitor list
changes, applying each spec through one `hyprctl eval 'hl.monitor({...})'`.
Needs plans 0 and 2a; 2a's parity test is the only evidence the crate can be
deleted safely, so do not start before it is green.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The watcher lives in `shell.qml`'s tree, so it exists only inside a
  graphical session. That is a deliberate narrowing from the systemd user
  service, which started slightly earlier. Do not re-add a unit for it.
- Overrides remain a separate document from the Nix-managed rules.
- FIX THE PARSE BUG 2a ported faithfully. Live `hyprctl monitors -j` emits
  `availableModes` as `1920x1080@60.00Hz`; `plan.rs`'s `parse_mode` parses
  the rate as a bare float, so the `Hz` suffix returns None for EVERY mode
  on every real machine and the planner silently falls back to the live
  `refreshRate`, never raising a monitor to its top rate. Strip a trailing
  `Hz`, and add a fixture carrying it: the Rust tests missed this only
  because their own fixtures omit the suffix.
- Apply is one `hyprctl eval 'hl.monitor({...})'` per spec, not a batch, and
  never the legacy `hyprctl keyword monitor`, which Hyprland 0.55+ disables
  under the Lua parser: it exits 0 and changes nothing, so a watcher built
  on it silently no-ops. A failing output must not take the others down.

---

### Task 1: The hotplug watcher
**Files:** create `qml/monitors/Watcher.qml`; modify `qml/shell.qml`.
**Consumes** 2a's `planFor`, `applyOverrides`, `render`.
**Produces** `apply()`, re-running the plan against the live monitor list.

- [ ] **1** Write `Watcher.qml`: read rules and overrides through
      `FileView` + `JsonAdapter`, and `Quickshell.Hyprland`'s monitor list
- [ ] **2** Wire a `Connections` block so a monitor change calls `apply()`
- [ ] **3** Apply each rendered spec with its own `Process`
- [ ] **4** Stop `hyprmon.service`, then hotplug a monitor Expected: the
      layout still returns, now from the shell. NOTE: needs a human to
      unplug something. If nobody is present, report it UNVERIFIED rather
      than faking it, and check `qs` logs show one `hyprctl` call per output
- [ ] **5** `git commit -m "watch for monitor hotplug in the shell"`

### Task 2: The arrange surface
**Files:** create `qml/monitors/Arrange.qml`; modify `qml/shell.qml`,
`nix/home/desktop/keybinds.nix`.
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
`nix/home/default.nix:38`, `nix/home/apps/settings-menu.nix`.

- [ ] **1** Re-run 2a's parity test Expected: PASS. If it fails, stop
- [ ] **2** `git rm -r rust/hyprmon nix/home/hyprmon.nix` and strip every
      reference above
- [ ] **3** Rename the rules file to `~/.config/dots-shell/monitors.json`
      and repoint `Watcher.qml` and `Arrange.qml`
- [ ] **4** `grep -rn 'hyprmon' .` no hits outside `docs/`; nix-lint green;
      `systemctl --user list-units | grep hyprmon` Expected: nothing
- [ ] **6** Rebuild, log out and back in, then hotplug a monitor
      Expected: the layout applies with no Rust binary present
- [ ] **7** `git commit -m "delete the monitor TUI"`
