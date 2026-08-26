# Quickshell Migration 1b: Wallpaper Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Draw the wallpaper picker in the shell, retire the icon-tint
walk, and delete `rust/wallpaper-tui`.
**Architecture:** A thumbnail grid drives `awww` through `Process`; the
accent maths comes from plan 1a. The MoreWaita tree is copied with `cp -r`
because QML has no directory-copy API, then only its blue-bearing SVGs are
rewritten from JS. Quickshell 0.3, Qt 6.11, awww.
**Depends on:** plans 0 and 1a. 1a's parity test is the only evidence the
crate can be deleted safely, so do not start before it is green.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- Icon theme name is `MoreWaita-Tint`. The `gsettings` switch is a no-op
  when the destination is missing, and must stay one.
- Tint state moves to `$XDG_STATE_HOME/dots-shell/tint/current.json`, and
  `tree.nix`'s `FileView` moves with it in the same commit or the accent
  silently falls back to `accentFallback`.
- Thumbnails cap at `sourceSize` 320x200, matching the old preview cache.

---

### Task 1: The icon tree
**Files:** create `qml/wallpaper/Icons.qml`.
**Consumes** `tint.js` `recolorIconText`. **Produces** `retint(accent)`.

- [ ] **1** Confirm the workload first: `find <base> -name '*.svg' | wc -l`
      gives 1467 and `grep -rlic` for the six blues gives 240. If either
      moved, stop and re-scope
- [ ] **2** Implement `retint`: `Process` `cp -r` to
      `$XDG_DATA_HOME/icons/MoreWaita-Tint`, a JS pass over those 240
      only, then `gsettings set` the icon theme
- [ ] **3** Run it, then `grep -rc '#1c71d8' <dest>` Expected: 0, and
      folder icons carry the accent in a file manager
- [ ] **4** Delete the destination and re-run Expected: it rebuilds
- [ ] **5** `git commit -m "recolour the icon theme from the shell"`

### Task 2: The picker and the awww calls
**Files:** create `qml/wallpaper/Picker.qml`; modify `qml/shell.qml`,
`nix/home/quickshell/tree.nix`, `nix/home/keybinds.nix`.
**Produces** a thumbnail grid and `apply(path, output, mode)`.

- [ ] **1** Build the grid over `Wallpapers/`, capped at 320x200
- [ ] **2** Wire selection to `awww` via `Process`, then to plan 1a's
      `accentFrom` and Task 1's `retint`
- [ ] **3** Repoint `tree.nix`'s `FileView` at the new state path
- [ ] **4** Bind the picker to a keybind in `keybinds.nix`
- [ ] **5** Pick a wallpaper Expected: it applies, and the bar's accent
      repaints with no home-manager switch
- [ ] **6** `nix run .#nix-lint` Expected: green
- [ ] **7** `git commit -m "draw the wallpaper picker in the shell"`

### Task 3: The hourly rotation
**Files:** create `qml/wallpaper/Rotation.qml`; modify `qml/shell.qml`;
delete `nix/home/random_wp.nix`.
**Produces** a `Timer` at 3600000ms replacing the systemd timer.

- [ ] **1** Write `Rotation.qml` calling `Picker.apply` with a random pick
- [ ] **2** Set the interval to 10000 temporarily Expected: it rotates
- [ ] **3** Restore 3600000, `git rm nix/home/random_wp.nix`, strip its
      import from `nix/home/default.nix`
- [ ] **4** `nix run .#nix-lint` Expected: green, and
      `systemctl --user list-timers | grep -i wallpaper` Expected: no hits
- [ ] **5** `git commit -m "rotate the wallpaper from the shell"`

### Task 4: Delete the crate
**Files:** delete `rust/wallpaper-tui/`, `nix/home/wallpaper-tui.nix`;
modify `flake/packages.nix:22-36`, `flake/apps.nix:122`,
`flake/nixos.nix:27`, `nix/home/default.nix`.

- [ ] **1** Re-run plan 1a's parity test Expected: PASS. If it fails, stop
- [ ] **2** `git rm -r` both paths, strip every reference above
- [ ] **3** `grep -rn 'wallpaper-tui' . --exclude-dir=.git` Expected: no
      hits outside `docs/`, then `nix run .#nix-lint` Expected: green
- [ ] **5** Rebuild, log out and back in Expected: the wallpaper restores
      and the accent is right on a cold start
- [ ] **6** `git commit -m "delete the wallpaper TUI"`
