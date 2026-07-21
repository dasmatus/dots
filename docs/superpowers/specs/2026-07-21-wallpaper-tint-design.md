# Wallpaper-derived accent tinting for `wallpaper-tui`

**Date:** 2026-07-21
**Status:** Approved-by-directive (goal hook)
**Scope:** Add accent-only color tinting, derived from the current wallpaper, to the
`wallpaper-tui` Python wallpaper changer. Tints four targets: Hyprland window
borders, Rofi, GTK (3 + 4) and Qt (Kvantum) themes, and the current icon theme
(MoreWaita).

## Decisions (from brainstorming)

- **Tint depth:** Accent-only shift. Keep the curated Tokyonight-Dark base
  everywhere; only move the accent/border/selection color toward a hue extracted
  from the wallpaper.
- **Trigger:** Tint fires from `wallpaper-tui` on every apply (TUI pick,
  non-interactive `--output/--path`, and `--restore`). The hourly random setter
  (`random_wp.nix`) is routed through `wallpaper-tui --output '*' <path>` so it
  inherits tinting and sheds its duplicate swaybg logic.
- **Palette backend:** Pure Python via Pillow, in-process. No external tool.
- **Qt:** Tint via a generated, recolored Kvantum theme (`WallpaperTint`),
  derived from a shipped base Kvantum theme; selected through `kvconfig`.
- **Injection mechanism:** State-import. Nix declarative configs `@import`
  runtime-state files the script writes; runtime selectors (`hyprctl keyword`,
  `gsettings`, `kvconfig`) re-apply on every tint. A HM rebuild resets only the
  `gsettings`/`kvconfig` targets (icon theme, Kvantum selection) until the next
  tint; the login service retints within seconds.

## Architecture

`wallpaper-tui` gains an `apply_tint(path)` orchestrator called after every
`apply_wallpaper` and inside `restore_all`. It is best-effort: each target is
wrapped in its own try/except, logs to stderr, and continues on failure so a
tint hiccup never blocks setting the wallpaper.

The inline Python currently living in `nix/home/wallpaper-tui.nix` (inside
`writers.writePython3Bin`) moves to a real file `nix/home/wallpaper-tui.py`,
sourced by Nix via `builtins.readFile ./wallpaper-tui.py`. This makes the module
importable by pytest, satisfying the repo rule "no inline tests; tests live in
`tests/`". It is a targeted improvement to the module while we are in it, not
unrelated refactoring.

A Hyprland `exec-once` runs `wallpaper-tui --restore` at session start so border
colors retint after a Hyprland reload.

### Data flow

```
wallpaper path
  -> extract_accent(path) -> (accent, accent_dark, accent_light)
  -> writers (pure):
       rofi_rasi(base_text, shades)   -> ~/.local/state/wallpaper-tui/tint/rofi.rasi
       gtk_css(shades)                -> …/tint/gtk3.css , …/tint/gtk4.css
       tint_kvantum(base, shades)     -> ~/.config/Kvantum/WallpaperTint/
       tint_icons(base, shades)       -> ~/.local/share/icons/MoreWaita-Tint/
  -> selectors (side-effecting):
       hyprctl keyword general:col.active_border …
       gsettings set org.gnome.desktop.interface icon-theme MoreWaita-Tint
       ~/.config/Kvantum/kvantum.kvconfig -> theme=WallpaperTint
  -> record {accent, source_path} in …/tint/current.json
```

## Components

Each component is a small, pure, unit-testable function (writers return strings;
I/O is in thin wrappers).

1. **`extract_accent(path: Path) -> tuple[str, str, str]`**
   Pillow: open image, convert RGB, thumbnail to ~64×64, read all pixels.
   Convert to HSL, drop near-black (L<0.1), near-white (L>0.9), and
   low-saturation (S<0.2) pixels. Bucket the rest by hue (16 bins), score each
   bucket by `Σ (saturation × frequency)`, pick the top bucket's mean hue.
   Remap to fixed target S=0.55, L=0.62 so the accent is always a usable UI
   color regardless of the wallpaper's original lightness. Derive
   `accent_dark` (L=0.40) and `accent_light` (L=0.78) keeping H and S. Return
   the triple as `#rrggbb` strings. On any Pillow/IO error, return
   `(DEFAULT_COLOR, DEFAULT_COLOR_DARK, DEFAULT_COLOR_LIGHT)`.

2. **`rofi_rasi(base_text: str, accent: str, accent_dark: str) -> str`**
   Read the read-only `tokyonight.rasi` text; substitute the `accent:` and
   `selected-bg:` rasi variable lines with the new hexes; return the full rasi.
   The runner writes it to `~/.local/state/wallpaper-tui/tint/rofi.rasi`.

3. **`gtk_css(shades, version: int) -> str`**
   Emit `@define-color` overrides loaded *after* the Tokyonight theme import:
   `theme_selected_bg_color`, `theme_selected_fg_color`, `accent_color`,
   `accent_bg_color` (gtk4 also `accent_fg_color`). Two files (gtk3, gtk4) in
   `…/tint/`, pulled in by Nix `gtk.gtk3.extraCss` / `gtk.gtk4.extraCss`
   `@import`s.

4. **`hyprland_borders(accent, accent_dark) -> list[str] | None`**
   Return `hyprctl keyword` argv (active_border = `rgba(<accent>ff)`,
   inactive_border = `rgba(<accent_dark>ff)`), or `None` when
   `HYPRLAND_INSTANCE_SIGNATURE` is unset / `hyprctl` missing. Runner shells
   out best-effort.

5. **`tint_kvantum(base_dir: Path, shades, dest: Path) -> None`**
   Copy the base Kvantum theme tree to `~/.config/Kvantum/WallpaperTint/`,
   shade-map the base accent hex family across every `*.svg` (base→accent,
   mid→accent_dark, light→accent_light), rewrite the `*.kvconfig` `name=`, and
   point `~/.config/Kvantum/kvantum.kvconfig` at `theme=WallpaperTint`.
   Implementation verifies the base theme's accent hexes by sampling its SVGs.

6. **`tint_icons(base_dir: Path, shades, dest: Path) -> None`**
   Copy MoreWaita to `~/.local/share/icons/MoreWaita-Tint/`, replace the
   Adwaita-blue family across all SVGs (`#62a0ea`→accent, `#438de6`→accent_dark,
   `#afd4ff`→accent_light, plus any other Adwaita-blue shades discovered by
   sampling), rewrite `index.theme` `Name=MoreWaita-Tint` (keep `Inherits=`).
   Runner does `gsettings set org.gnome.desktop.interface icon-theme
   MoreWaita-Tint`.

7. **`apply_tint(path: Path) -> dict`**
   Orchestrator. Extract → write rofi/gtk3/gtk4 → hyprctl borders → kvantum →
   icons. Each step isolated. Records `{accent, source_path}` in
   `…/tint/current.json`. Returns a per-target status dict (for logging).

### Caching

Stable destination names (`WallpaperTint`, `MoreWaita-Tint`, fixed `tint/`
filenames). Regenerate SVG trees only when the accent changes (compare against
`current.json`); otherwise skip the copy+recolor and just re-apply the cheap
selectors. Accent extraction itself is ~10 ms on a 64² thumbnail, so the hourly
random path stays fast.

## Nix changes

- **`nix/home/wallpaper-tui.nix`**: `writePython3Bin` over
  `builtins.readFile ./wallpaper-tui.py`; add `python3Packages.pillow` to
  `libraries`; add
  `gtk.gtk3.extraCss = ''@import url("file://${config.xdg.stateHome}/wallpaper-tui/tint/gtk3.css");''`
  and the analogous `gtk.gtk4.extraCss`. (HM appends `extraCss` after the theme
  `@import`, so the override wins.)
- **`nix/home/hyprland.nix`**: three rofi binds change from `-theme tokyonight`
  to `-theme ${xdg.stateHome}/wallpaper-tui/tint/rofi.rasi`; add
  `exec-once` `wallpaper-tui --restore` if not already present.
- **`nix/home/random_wp.nix`**: replace the swaybg tail with
  `wallpaper-tui --output '*' "$img_path"`; keep the Wallhaven download/cache
  logic intact.
- **`nix/home/default.nix`**: add a Kvantum base theme package and set
  `qt.style.kvantum.theme` (verify the HM option exists; if not, set
  `xdg.configFile."Kvantum/kvantum.kvconfig"` to point at the base, which the
  script later overrides with `WallpaperTint`).

## Testing (`tests/wallpaper_tui/`, pytest, pure functions)

Per repo rule, tests live under `tests/`, no inline tests.

- `test_extract_accent.py`: solid-red image → red-family accent; grayscale →
  fallback default; mostly-blue-with-small-red → blue accent (dominant vibrant
  wins over a tiny saturated patch).
- `test_tint_writers.py`: `rofi_rasi` replaces `accent:`/`selected-bg:` and
  leaves the rest structurally intact; `gtk_css` emits the expected
  `@define-color` lines for each version; `tint_kvantum`/`tint_icons` SVG
  mapping replaces *only* the Adwaita-blue/base-accent family and rewrites
  `index.theme`/`*.kvconfig` names.
- I/O wrappers tested with `tmp_path` fixtures (no real `~/.config` writes).
- A `just py-test` target (pytest in `tests/wallpaper_tui/`); optionally fold
  into `just nix-lint`.

## Error handling & CLI

- Unreadable image / Pillow error → fall back to last accent or
  `DEFAULT_COLOR`, never crash the apply.
- Missing `hyprctl` / Kvantum base / icon base → skip that target with a stderr
  warning, continue.
- `--no-tint` flag skips tinting entirely. `--restore` retints from
  `current.json` (or re-extracts from the stored wallpaper path).
- Tint never blocks wallpaper application: `apply_wallpaper` runs first, then
  `apply_tint` best-effort.

## Risks

- **Kvantum base theme:** no Kvantum theme is configured today
  (`~/.config/Kvantum/` absent). The implementation must ship/select a base
  theme and verify its accent hexes by sampling. Highest-risk target; degrades
  gracefully (skip + warn) if the base is unusable.
- **`@import` of a not-yet-generated state file** (fresh boot, before the
  login service runs): GTK logs a CSS warning and continues; the window is
  seconds until `wallhaven-wallpaper`/`--restore` generates the files.
- **HM rebuild resets `gsettings` icon-theme and `kvconfig`** to the base until
  the next tint. Accepted; retint fires at login and on every apply.