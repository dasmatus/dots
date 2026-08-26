# Quickshell Migration 0: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Make the QML tree able to host the three TUIs, changing no
behaviour.
**Architecture:** One config tree, two roots. `shell.qml` keeps the
desktop; a new `installer.qml` is the LiveISO root, so cage never loads
`Quickshell.Hyprland`. Shared widgets move to `common/`.
**Tech Stack:** Quickshell 0.3, Qt 6.11, Nix flake, QtTest.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The palette lives at `nix/palette.json` after Task 1. Nothing reads
  `rust/palette.json` again.
- `installer.qml` must not import `Quickshell.Hyprland` at any depth.
- qmllint runs `--max-warnings 0`; a warning is a failure.
- "QtTest" below means the `qmltestrunner` line at `flake/apps.nix:115`.

---

### Task 1: Relocate the palette out of `rust/`
**Files:** move `rust/palette.json` -> `nix/palette.json`; modify
`nix/home/quickshell/tree.nix:29`, `flake/checks.nix:261`.
**Produces:** `nix/palette.json`, byte-identical content and schema.

- [ ] **1** `git mv rust/palette.json nix/palette.json`
- [ ] **2** Repoint `tree.nix:29` `builtins.readFile` from
      `../../../rust/palette.json` to `../../palette.json`
- [ ] **3** Repoint `flake/checks.nix:261` the same way
- [ ] **4** `grep -rn 'rust/palette.json' . --exclude-dir=.git`
      Expected: no hits
- [ ] **5** `nix build .#quickshell-config &&
      grep -c '#1a1b26' result/Theme.qml` Expected: >= 1
- [ ] **6** `nix run .#nix-lint` Expected: green
- [ ] **7** `git commit -m "refactor: move the palette out of the Rust tree"`

### Task 2: Extract the shared widgets into `common/`
**Files:** create `qml/common/Panel.qml`, `qml/common/hls.js`,
`tests/qml/tst_hls.qml`; modify `qml/settings/Settings.qml`,
`qml/launcher/Launcher.qml`.
**Produces:** `Panel.qml`, a `Theme.bg` + `Theme.alphaPanel` surface with
`radius` and `padding` properties; `hls.js` exporting `rgbToHls(r,g,b)`
and `hlsToRgb(h,l,s)`, 0-1 floats in and out, ported verbatim from
`rust/wallpaper-tui/src/accent.rs` so its test vectors still apply.

- [ ] **1** Write `tests/qml/tst_hls.qml`: assert `#7aa2f7` survives a
      round trip, and that `(1,0,0)` gives `h=0, l=0.5, s=1`
- [ ] **2** Run QtTest Expected: FAIL, "module hls.js not found"
- [ ] **3** Port `rgb_to_hls`/`hls_to_rgb` into `hls.js`
- [ ] **4** Run QtTest Expected: PASS
- [ ] **5** Move the panel chrome duplicated by `Settings.qml` and
      `Launcher.qml` into `Panel.qml`; both import `".."`
- [ ] **6** `nix run .#nix-lint` Expected: green
- [ ] **7** Open the launcher on SUPER+space Expected: unchanged
- [ ] **8** `git commit -m "refactor: share the panel chrome and the HLS pair"`

### Task 3: Add the second root
**Files:** create `qml/installer.qml`; modify
`nix/home/quickshell/tree.nix` (copy both roots), `flake/apps.nix:103`
(qmllint over both).
**Produces:** `installer.qml`, a `ShellRoot` drawing one `Panel` reading
"installer". Real screens arrive in plan 3.

- [ ] **1** Write `installer.qml` importing only `QtQuick`, `Quickshell`
      and `"."`
- [ ] **2** `nix build .#quickshell-config && test -f result/installer.qml`
      Expected: exit 0
- [ ] **3** `grep -rn 'Quickshell.Hyprland' result/installer.qml`
      Expected: no hits
- [ ] **4** `QT_QPA_PLATFORM=wayland qs -p result/installer.qml`
      Expected: a panel reading "installer"
- [ ] **5** `nix run .#nix-lint` Expected: green
- [ ] **6** `git commit -m "feat: give the shell tree a second root"`
