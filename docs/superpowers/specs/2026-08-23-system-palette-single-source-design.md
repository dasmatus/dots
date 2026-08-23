# One system palette, hot-reloaded

Status: design approved, pending implementation plan
Date: 2026-08-23

## Goal

Give the desktop a single source of truth for its colours, and make a palette
change take effect without a `home-manager switch`, a logout, or a visible app
restart.

Two properties, split by who owns what:

- **Neutrals** (panel, text, border, muted, the Tokyo Night ramp) come from one
  checked-in file and are baked into each app's config at build time.
- **The accent** is derived from the current wallpaper at runtime and is
  authoritative everywhere. Every static accent in the repo demotes to a
  fallback used only before a wallpaper accent exists.

## Decisions

| Question | Decision |
|---|---|
| Source-of-truth mechanism | One JSON file read by both Nix (`builtins.fromJSON`) and Rust (`include_str!`) |
| Base palette | Tokyo Night. beamenu conforms outward; commit `573799b`'s move to the "binding design palette" is reverted for the theme defaults |
| Accent owner | Wallpaper-derived, authoritative on every surface |
| Scope | All five phases below |
| GNOME dconf `accent-color` | Driven from the wallpaper accent, snapped to the nearest of GNOME's 9 keywords |
| Orphaned `rofi.rasi` | Wired to dunst's surviving `rofi -dmenu` call |
| Rust TUI palettes | Pulled from the palette file; `hyprmon` gains a theme instead of rendering in library defaults |

The base-palette decision reverses a deliberate change made the previous day
(`573799b`, "move theme defaults off Tokyonight"). It was raised explicitly and
reaffirmed. The consequence is that `config.rs` and `beamenu-canvas/src/theme.rs`
lose their "binding design palette" comments and values.

## Current state

### Five palettes, none derived from another

| Cluster | Values | Reach |
|---|---|---|
| Tokyo Night static chrome | `#1a1b26`, `#c0caf5`, `#7aa2f7`, `#737aa2`, `#414868` + ramp | waybar, kitty, dunst, zellij, eww, hyprlock, nixvim, Zed, rofi |
| beamenu "binding design" | `#0d1013`, `#e6ebef`, `#5b6672`, `#1e252c`, accent `#7fd6c2`, on-accent `#08110e` | beamenu, beamenu-canvas |
| Wallpaper-derived accent | computed per wallpaper; falls back to `#7aa2f7` | GTK, Kvantum, icons, Hyprland borders (intended) |
| Upstream base themes | dconf `accent-color = "red"`, Kvantum seeded from catppuccin-frappe-blue, MoreWaita Adwaita-blue | GTK4/libadwaita, Qt, icons |
| beamenu-canvas ANSI ramp | 16-slot SGR set, e.g. `#e0685f`, `#6fa8e0` | canvas log views |

Hyprland's borders are a sixth value again: `hyprland.nix:159-162` declares
`rgba(9aa5ceff)` / `rgba(16161dff)`, matching neither the Tokyo Night blue nor
the wallpaper accent.

84 colour sources were catalogued across `nix/`, `rust/` and standalone theme
assets. Only two standalone theme files exist — `nix/home/eww/eww.scss` and
`nix/home/rofi/tokyonight.rasi`. Everything else is a hex literal inside Nix or
Rust.

### Three verified bugs

All three are the same defect: **a side-effecting call whose result nobody
checks.**

1. **Hyprland border tinting is a no-op.** `tint.rs:152-172` emits
   `hyprctl keyword general:col.active_border`. `hyprland.nix:39` sets
   `configType = "lua"`, and Hyprland 0.55+ retired the hyprlang `keyword` IPC
   for the Lua parser — the call exits 0 and changes nothing. `hyprmon` already
   documents this (`runner.rs:7-9`) and was migrated to
   `hyprctl eval 'hl.monitor({...})'`; `wallpaper-tui` was missed.
   `tint.rs:417` discards the result with `let _ =`.

   *Confirmed live:* `hyprctl getoption general:col.active_border` returns
   `ff9aa5ce`, the static Nix value.

2. **`theme.canvas` is read but never written.** `beamenu-canvas/src/config.rs:19`
   reads `theme.canvas`; `beamenu.nix:48-59` emits a flat `theme` object and no
   `canvas` key. `CanvasTheme::default()` is therefore the only value the sidecar
   ever uses, and `programs.beamenu.accent` has no effect on it at all.

3. **The icon theme is generated and never selected.** `tint.rs:341-355` shells
   out to `gsettings`, which is on no profile on this system — not
   `/run/current-system/sw/bin`, not `~/.nix-profile/bin`, not
   `/etc/profiles/per-user/matus/bin` — and `wallpaper-tui.nix:50` puts only
   `pywal` on PATH. The MoreWaita-Tint tree is recoloured per-SVG on every
   accent change (`tint.rs:450`) and then discarded.

   Separately, `.status().is_ok()` is `true` for a nonzero exit, so it only
   detects spawn failure, never a gsettings error.

### Duplication

- The beamenu palette is written three times (`beamenu.nix:34-44`,
  `config.rs:49-60`, `beamenu-canvas/src/theme.rs:36-65`) with comments asking
  humans to keep them in sync. They already disagree in string form.
- `"Lilex Nerd Font"` is hardcoded in ~10 files; beamenu-canvas independently
  uses Manrope/JetBrains Mono.
- `installer-tui/src/ui.rs` and `wallpaper-tui/src/ui.rs` each carry their own
  Tokyo Night `Rgba` table. `hyprmon` has no colours at all — nothing calls
  `provide_theme`, so it renders in `abstracttui`'s defaults.

## Architecture

```
rust/palette.json          neutrals + ramp, fonts, metrics, fallback accent
      │
      ├─ build time ── builtins.fromJSON ──→ nix/home/** emit static configs
      │                include_str!      ──→ Rust Default impls (fallbacks only)
      │
      └─ runtime ───── wallpaper-tui apply_tint
                         ├ derives the accent from the wallpaper (authoritative)
                         ├ writes colour-only fragments → $XDG_STATE_HOME/wallpaper-tui/tint/
                         └ signals each live consumer
```

### The reload seam

`nix/home/default.nix:159-164` already has Nix-managed GTK CSS `@import` a
runtime-written fragment. That pattern — **static structure from Nix, colour
from a mutable fragment** — is the whole design, generalised from its single
current use to every store-blocked surface:

| Surface | Seam |
|---|---|
| GTK 3/4 | `@import` (exists today) |
| kitty | `include` directive → `tint/kitty.conf` |
| zellij | `themes/` dir entry → `tint/zellij.kdl` |
| dunst | `dunstrc` seeded once as a mutable copy, not a symlink |
| hyprlock | `source` → `tint/hyprlock.conf` |

No new daemon, watcher, or D-Bus service. The trigger already exists (wallpaper
change), the writer already exists (`apply_tint`), the seam already exists
(`@import`); only the target list grows.

### Reload classes

| Class | Surfaces | Mechanism |
|---|---|---|
| Live | Hyprland borders, wallpaper, waybar, eww, dunst | `hyprctl eval`, awww socket, `SIGUSR2`, `eww reload`, `dunstctl reload` |
| Cheap restart | beamenu, canvas, settings-global, GTK apps, Kvantum, kitty, zellij, hyprlock, icons | re-read config on next spawn |
| Rebuild | installer-tui, wallpaper-tui, hyprmon | palette is compiled in |
| Unreachable | libadwaita `accent-color` | see Limitations |

beamenu, beamenu-canvas and the settings menu need **no** new mechanism.
`beamenu.nix:10-14` records that the resident-scratchpad machinery was dropped
because "layer-shell plus cairo starts in tens of milliseconds, so SUPER+D just
runs the binary" — every invocation is a fresh process reading config at
startup. Merging the tint fragment over the store config makes them hot by
construction.

## Palette file

`rust/palette.json`. Base colours are 6-digit; alpha is applied per consumer at
the seam, because bemenu wants `#RRGGBBAA` while the canvas's `hex_to_rgba`
wants `#RRGGBB` and re-applies alpha in CSS. Neither format is canonical, so
neither is stored.

```json
{
  "colors": {
    "bg": "#1a1b26", "bgDark": "#1f2335", "bgDarker": "#15161e",
    "fg": "#c0caf5", "fgDark": "#a9b1d6", "muted": "#737aa2",
    "border": "#414868", "selection": "#3b4261",
    "blue": "#7aa2f7", "cyan": "#7dcfff", "green": "#9ece6a",
    "magenta": "#bb9af7", "red": "#f7768e", "yellow": "#e0af68",
    "orange": "#ff9e64", "dim": "#565f89"
  },
  "accentFallback": "#7aa2f7",
  "alpha": { "panel": "f2", "heading": "ee", "opaque": "ff" },
  "fonts": {
    "ui": "Lilex Nerd Font",
    "mono": "Lilex Nerd Font",
    "size": 12,
    "canvasUi": "Manrope",
    "canvasMono": "JetBrains Mono"
  },
  "beamenu": {
    "lines": 9, "widthFactor": 0.375, "iconSize": 24,
    "lineHeight": 52, "searchHeight": 56, "radius": 16
  }
}
```

Two things about this shape are deliberate:

- **The canvas keeps its distinct typography.** beamenu-canvas is a WebKit
  surface using Manrope/JetBrains Mono rather than the desktop's Lilex. Naming
  those as roles in the palette file de-duplicates the strings without forcing
  them to converge — the divergence becomes a declared choice rather than an
  accident of a second hardcoded list. Collapsing them to Lilex is a separate
  decision, not implied by this work.
- **`beamenu` is an app-scoped section.** Layout metrics are not system colours,
  but they are duplicated between `beamenu.nix`'s `mkOption` defaults and
  `config.rs`'s `default_*()` fns in exactly the same way, and they cannot be
  de-duplicated by a different mechanism than the colours without adding a
  second file. Other apps get their own section if the same problem appears.

### Packaging

Both Rust derivations must widen `src`, since the file sits above both crate
directories:

```nix
src = lib.fileset.toSource {
  root = ../rust;
  fileset = lib.fileset.unions [ ../rust/beamenu ../rust/palette.json ];
};
sourceRoot = "source/beamenu";
```

`cargoLock.lockFile` stays an eval-time path and is unaffected. The exact
`sourceRoot` / `cargoRoot` form is to be verified against a real `nix build`
rather than assumed — this is the least certain part of the design.

## Phases

Phase 2 is independent of the architecture and lands first as its own commit.

| Phase | Work |
|---|---|
| **1** | `palette.json`; collapse beamenu's three copies; emit `theme.canvas`; redirect Nix modules and Rust `Default` impls |
| **2** | `hyprctl keyword` → `hyprctl eval 'hl.config({...})'`; check the result instead of `let _ =` |
| **3** | Extend `apply_tint`: waybar (`SIGUSR2`), eww (`eww reload`), dunst (`dunstctl reload`); add `pkgs.glib` to the wrapper PATH; write dconf `accent-color` |
| **4** | `@import` seam for kitty, zellij, hyprlock, dunst |
| **5** | Wire `rofi.rasi` to dunst's `rofi -dmenu`; de-duplicate the font string; pull TUI palettes from the file; give `hyprmon` a theme; reseed Kvantum from a Tokyo Night base |

**Each phase gets its own implementation plan.** The five together are too large
for one plan to stay useful — phase 1 alone spans three crates, a Nix module and
`flake/packages.nix`. Phases 1 and 2 are independent of each other; 3 depends on
1 for the palette file and on 2 for a working border path; 4 depends on 3's
writer; 5 is cleanup and depends on 1.

## Testing

Per repo convention, Rust integration tests live in each crate's `tests/`
directory, not inline.

- **Round-trip assertions, to catch the bug family above.** A test asserting the
  Nix-rendered `config.json` contains every key its consumers read would have
  caught bug 2 at build time. This is the single most valuable test here.
- `beamenu-canvas/tests/theme.rs` already asserts all eleven canvas literals, so
  it becomes a free regression gate on the palette indirection — its values
  change to Tokyo Night's in the same commit that redirects them.
- A new `rust/beamenu/tests/palette.rs` asserting the eight launcher slots
  resolve correctly, and that a non-default accent moves `selected_background`
  and `heading` with it.
- `hyprland_border_commands_for` is already pure and testable; assert it emits
  `eval` + `hl.config`, never `keyword`.
- `nix run .#nix-lint` for flake eval, fmt and clippy; `nix run .#nix-smoke` for
  the ISO boot check.
- Live verification of the accent path must not run against the active session.
  Use a nested headless Hyprland with `grim` for screenshots.

## Limitations

- **libadwaita `accent-color` is unreachable.** `hyprland.nix:909` pins
  `org.freedesktop.portal.Settings` to the GTK backend, and
  `xdg-desktop-portal-gtk` never implements the `appearance:accent-color` key.
  No gsettings write, restart, or logout surfaces it. Changing the portal
  backend is out of scope. The dconf write in phase 3 still helps GNOME-native
  consumers that read the key directly; it does not fix libadwaita chrome.
- **The dconf accent snaps to 9 hues.** GNOME's schema permits only `blue`,
  `teal`, `green`, `yellow`, `orange`, `red`, `pink`, `purple`, `slate`. An
  arbitrary wallpaper hex cannot be expressed exactly; the mapping picks the
  nearest.
- **The derivation rule is expressed twice.** `accent + "ff"` appears once in
  Nix and once in Rust, because Nix owns the configured accent while Rust needs
  a standalone fallback and serde defaults cannot read sibling fields. Storing
  the alpha constants in the palette file keeps the shared part shared; only the
  concatenation is duplicated, and both sides are tested.
- **The three Rust TUIs cannot hot-reload.** Their palette is compiled in, so a
  change needs `nix build`. They are in scope for de-duplication, not for hot
  reloading.
- **Kvantum's base stays Catppuccin Frappé Blue.** Its neutrals never matched
  Tokyo Night; the wallpaper accent recolours it, which is why nobody noticed.
  Reseeding it from a Tokyo Night base is folded into phase 5.

## Out of scope

- Swapping the xdg-desktop-portal backend.
- Removing rofi entirely — it stays as a rendering dependency of the settings
  menu and dunst's dmenu.
- Cursor theme (`XCURSOR_THEME=Adwaita`), which needs a session restart.
