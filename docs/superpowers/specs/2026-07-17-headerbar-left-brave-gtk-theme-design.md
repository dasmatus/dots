# Header buttons left + Brave follows the GTK theme

Date: 2026-07-17 · Status: approved (user picked the GTK-follow approach and
approved the design in-session)

## Goal

Two Home Manager changes on the tokyonight machine:

1. Move window header (titlebar) buttons to the left edge.
2. Make Brave use the same theme as Alacritty — clarified by the user as
   "same GTK theme": Brave's chrome should follow the Tokyonight-Dark GTK
   theme that Alacritty's hardcoded palette already matches.

## Background (verified during brainstorming)

- `gtk.theme` is Tokyonight-Dark with `tweakVariants = [ "macos" ]` (traffic-
  light buttons); Alacritty's colors are the Tokyo Night *night* palette
  (`#1a1b26` / `#c0caf5`), i.e. the same palette the GTK theme renders.
- Chromium stores the Linux "use GTK theme" appearance choice per-profile in
  `Preferences` → `extensions.theme.system_theme`; `ui::SystemTheme::kGtk = 1`
  (verified in Chromium source: `ui/color/system_theme.h`,
  `chrome/common/pref_names.h`). There is no enterprise policy and no Home
  Manager option for it.
- Chromium/Brave reads `org.gnome.desktop.wm.preferences button-layout` for
  its own caption buttons, so change 1 also moves Brave's window controls.

## Design

### 1. Button layout (`nix/home/default.nix`)

Add to the existing `dconf.settings` block:

```nix
"org/gnome/desktop/wm/preferences".button-layout = "close,minimize,maximize:appmenu";
```

macOS traffic-light order on the left, matching the GTK theme's macos tweak.
Applies to GNOME Shell, GTK CSD headerbars, and Brave's caption buttons.

### 2. Brave GTK-follow (`nix/home/apps/brave.nix`)

`home.activation.braveGtkTheme` (DAG: after `writeBoundary`):

- Target: `${config.xdg.configHome}/BraveSoftware/Brave-Browser/Default/Preferences`.
- Skip silently when the file doesn't exist (Brave not launched yet); the
  next activation after first launch applies it.
- Idempotent: probe with `jq -e '.extensions.theme.system_theme == 1'`; only
  rewrite (jq to a temp file, then `mv`) when the value differs.
- `jq` comes from `${lib.getExe pkgs.jq}`; mutations go through HM's `run`
  wrapper so `--dry-run` stays side-effect-free.

Accepted limitation: if Brave is running during a switch it may rewrite
`Preferences` on exit; the next switch re-asserts the value. Only the
`Default` profile is managed.

### 3. Alacritty

No change — already the exact palette.

## Verification

- `just nix-lint` (mind the facter/settings stub dance on this machine —
  see memory `machine-answers-skip-worktree`).
- After `switch`: `gsettings get org.gnome.desktop.wm.preferences
  button-layout`; `jq .extensions.theme.system_theme` on the Brave
  Preferences file; visual check of a GTK app and Brave.
