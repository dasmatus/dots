# Header Buttons Left + Brave GTK-Follow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move window header buttons to the left edge and make Brave's chrome follow the Tokyonight-Dark GTK theme (the palette Alacritty already uses).

**Architecture:** Two independent Home Manager edits in the existing NixOS+HM flake: one dconf key in `nix/home/default.nix`, and one idempotent `home.activation` entry in `nix/home/apps/brave.nix` that patches Brave's per-profile `Preferences` JSON (`extensions.theme.system_theme = 1`, `ui::SystemTheme::kGtk`) — no policy or HM option exists for this pref.

**Tech Stack:** Nix flakes, Home Manager (`dconf.settings`, `home.activation`, `lib.hm.dag`), jq.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-17-headerbar-left-brave-gtk-theme-design.md` (approved).
- **Do NOT `git commit` the nix files.** The index carries the user's unrelated in-flight changeset (`flake.nix`, `flake.lock`, `nix/home/*`, staged `core.*` dumps); committing these paths would sweep their working-tree state in. Leave committing to the user.
- Do NOT touch `nix/data/facter.json` / `nix/data/settings.nix` except via the Task 3 stub dance (they're `skip-worktree`-parked machine answers; see memory `machine-answers-skip-worktree`).
- Comments in this repo: `#` prose explaining the *why*, in the style of the surrounding files.
- Nix-only change: the cargo half of `just nix-lint` is out of scope (Rust untouched; `just`/`cargo` not on PATH here — invoke `nix flake check --no-build` directly).

---

### Task 1: Button layout → left (dconf)

**Files:**
- Modify: `nix/home/default.nix` (the `dconf.settings` block, currently lines 40–47)

**Interfaces:**
- Produces: dconf key `org/gnome/desktop/wm/preferences` `button-layout` = `"close,minimize,maximize:appmenu"` (read by GNOME Shell, GTK CSD headerbars, and Chromium/Brave caption buttons).

- [ ] **Step 1: Add the key to the existing `dconf.settings` attrset**

```nix
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      accent-color = "red";
    };
    # Traffic-light order on the left — completes the GTK theme's macos
    # tweak (gtk.theme below); Brave's caption buttons read this key too.
    "org/gnome/desktop/wm/preferences" = {
      button-layout = "close,minimize,maximize:appmenu";
    };
    "org/gnome/desktop/input-sources" = {
      xkb-options = [ "ctrl:esc" ];
    };
  };
```

- [ ] **Step 2: Verify by eval**

Run:
```bash
nix eval '.#nixosConfigurations.tokyonight.config.home-manager.users.matus.dconf.settings' \
  --apply 's: s."org/gnome/desktop/wm/preferences".button-layout'
```
Expected: `"close,minimize,maximize:appmenu"`
(If the username differs, check `nix eval --impure --expr '(import ./nix/data/settings.nix).username'`.)

### Task 2: Brave GTK-follow activation script

**Files:**
- Modify: `nix/home/apps/brave.nix` (module args + new `home.activation` entry; keep the existing header comment and `programs.brave` block byte-identical)

**Interfaces:**
- Consumes: nothing from Task 1 (independent).
- Produces: `home.activation.braveGtkTheme` DAG entry after `writeBoundary`.

- [ ] **Step 1: Change the module args and append the activation entry**

Args line `{ ... }:` becomes `{ config, lib, pkgs, ... }:`.
After the `programs.brave` attrset, add:

```nix
  # Appearance "GTK" mode has no browser policy and no HM option: the choice
  # lives per-profile in Preferences → extensions.theme.system_theme
  # (ui::SystemTheme::kGtk = 1). Assert it on activation so Brave's chrome
  # follows Tokyonight-Dark GTK3 — the same palette alacritty.nix hardcodes.
  # No-op before Brave's first launch; a Brave exit during a switch may
  # rewrite the file, so the next switch re-asserts it. Default profile only.
  home.activation.braveGtkTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    prefs=${lib.escapeShellArg "${config.xdg.configHome}/BraveSoftware/Brave-Browser/Default/Preferences"}
    if [ -f "$prefs" ] && ! ${lib.getExe pkgs.jq} -e '.extensions.theme.system_theme == 1' "$prefs" >/dev/null; then
      run sh -c '${lib.getExe pkgs.jq} ".extensions.theme.system_theme = 1" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh "$prefs"
    fi
  '';
```

Notes for the implementer:
- The probe (`jq -e … == 1`) runs outside HM's `run` wrapper on purpose — it is read-only; the mutation goes through `run` so `--dry-run` only echoes.
- `sh -c '… "$1" …' sh "$prefs"` passes the path as a positional arg so no extra shell-quoting layer is needed inside the Nix string.
- If jq ever fails to parse the file, `&&` skips the `mv` (a stray empty `.tmp` may remain — accepted).

- [ ] **Step 2: Verify by eval**

Run:
```bash
nix eval --raw '.#nixosConfigurations.tokyonight.config.home-manager.users.matus.home.activation.braveGtkTheme.data'
```
Expected: the script text with a `/nix/store/…/bin/jq` path and the
`…/.config/BraveSoftware/Brave-Browser/Default/Preferences` target; no
literal `${…}` leftovers.

### Task 3: Repo gate

- [ ] **Step 1: Format only the touched files**

Run: `nix fmt -- nix/home/default.nix nix/home/apps/brave.nix`
Expected: exit 0; `git diff --stat` shows no unrelated files reformatted.

- [ ] **Step 2: `nix flake check --no-build` with the stub dance**

```bash
git update-index --no-skip-worktree nix/data/facter.json nix/data/settings.nix
git restore --source=HEAD -- nix/data/facter.json nix/data/settings.nix
nix flake check --no-build; status=$?
cp /var/lib/dots/facter.json nix/data/facter.json
cp /var/lib/dots/settings.nix nix/data/settings.nix
git update-index --skip-worktree nix/data/facter.json nix/data/settings.nix
exit $status
```
Expected: check passes; afterwards `git status --short` shows neither
`nix/data/facter.json` nor `nix/data/settings.nix`. (`ls /var/lib/dots/` first to
confirm the pristine copy filenames.)

- [ ] **Step 3: No commit** — report the diff to the user instead (see Global Constraints).

## Self-review

- Spec coverage: §1 button layout → Task 1; §2 Brave GTK-follow (skip-if-absent, idempotent probe, `run`/dry-run, `lib.getExe`) → Task 2; §3 Alacritty no-op → no task by design; verification section → eval steps + Task 3. No gaps.
- No placeholders; all code complete.
- Names consistent: `braveGtkTheme`, `button-layout` string identical across spec/plan.
