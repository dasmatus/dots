# Hyprland config → Home Manager Lua DSL

**Date:** 2026-07-19
**Scope:** single-file edit of `nix/home/hyprland.nix` — the
`wayland.windowManager.hyprland.settings` block plus its header comment. No
Rust, no new files, no other modules touched.

## Goal

Migrate the Hyprland config from the classic hyprlang format to Hyprland's
Lua DSL, keeping the config **declarative in Nix** (Home Manager's `settings`
attrset auto-converts to `hl.*(...)` Lua calls when `configType = "lua"`).

## Background (verified)

- `home.stateVersion = "26.05"` (`nix/home/default.nix`), so HM's
  `configType` default already flips to `"lua"` via
  `mkStateVersionOptionDefault`. The current `configType = "hyprlang"` pin
  (line 34) is the only thing holding the old format.
- HM's lua backend (`home-manager` `modules/services/window-managers/hyprland/lib.nix`,
  `renderSettings`) is a generic walker: every top-level `settings` key →
  `hl.<key>(<args>)`; list values → one call per element; `_args` → multi-arg
  call; `_var` → `local`; `lib.generators.mkLuaInline` → raw lua.
- Hyprland's `hl.*` API has **no** `bindm`/`binde`/`bindl`/`exec-once`/
  `bezier`/`animations` functions. hyprlang-only keys and comma-string values
  must be re-expressed in `hl.*` vocabulary.
- Dispatcher mappings confirmed against `hyprwm/Hyprland` C++ source
  (`src/config/lua/bindings/LuaBindingsDispatchers.cpp`) and the wiki
  (`Configuring/Basics/Dispatchers.md`).

## Decisions (confirmed with user)

1. **Pure declarative Nix** — stay in `hyprland.nix`, flip `configType`, re-shape
   `settings`. No hand-written `.lua` files, no `extraLuaFiles`.
2. **`configType = "lua"` kept explicit** (not dropped to rely on the default).
3. **Resolve the `SUPER+SHIFT+S` double-bind:** drop the
   `SUPER+SHIFT+S → exec flameshot gui` entry (current line 132); keep
   `SUPER+SHIFT+S → movetoworkspace special:magic` (line 186) and
   `SUPER+S → togglespecialworkspace magic` (line 185). `Print` keeps
   flameshot (recent commit `558d51a`).

## Transform rules

| Current (hyprlang) | New (lua `settings`) | Emits |
|---|---|---|
| `configType = "hyprlang"` | `configType = "lua"` | — |
| `"$mainMod" = "SUPER"` | `mod = { _var = "SUPER"; };` | `local mod = "SUPER"` |
| `monitor = "eDP-1, 1920x1080, 0x0, 1"` | `monitor = { output = "eDP-1"; mode = "1920x1080"; position = "0x0"; scale = 1; };` | `hl.monitor({…})` |
| `"exec-once" = [ "waybar" … ]` | `on = { _args = [ "hyprland.start" (lua ''function()\n … end'') ]; };` | `hl.on("hyprland.start", function() … end)` |
| `env = [ "X,24" … ]` | `env = [ { _args = [ "X" "24" ]; } … ];` | `hl.env("X","24")` |
| `general."col.active_border"` (dotted) | `general.col = { active_border = …; inactive_border = …; };` (nested) | `col = { … }` |
| `general/decoration/dwindle/master/misc/input` | nested under one `config = { … };` | one `hl.config({…})` |
| `animations.bezier = "myBezier,0.05,0.9,0.1,1.05"` | `curve = [ { _args = [ "myBezier" { type = "bezier"; points = [ [0.05 0.9] [0.1 1.05] ]; } ]; } ];` | `hl.curve("myBezier",{…})` |
| `animations.animation = [ "windows,1,7,myBezier" … ]` | `animation = [ { leaf="windows"; enabled=true; speed=7; bezier="myBezier"; } … ];` + `config.animations = { enabled = true; };` | `hl.animation({…})` |
| `bind = [ "$m,Q,killactive" … ]` | `bind = [ { _args = [ (lua ''mod.." + Q"'') (lua "hl.dsp.window.close()") ]; } … ];` | `hl.bind(…, …)` |
| `binde = [ "$m ALT,H,resizeactive,-40 0" … ]` | `bind` entry with third `_args` elem `{ repeating = true; }` | `hl.bind(…, …, { repeating = true })` |
| `bindm = [ "$m,mouse:272,movewindow" … ]` | `bind` entry with third `_args` elem `{ mouse = true; }` | `hl.bind(…, …, { mouse = true })` |

`let lua = lib.generators.mkLuaInline; in` at module top abbreviates each bind.

### Dispatcher map (all 14, source-confirmed)

| hyprlang | `hl.dsp.*` |
|---|---|
| `killactive` | `hl.dsp.window.close()` |
| `togglefloating` | `hl.dsp.window.float({ action = "toggle" })` |
| `fullscreen, 0` | `hl.dsp.window.fullscreen()` (defaults: mode="fullscreen", action="toggle") |
| `pseudo` | `hl.dsp.window.pseudo()` |
| `movefocus, l/r/u/d` | `hl.dsp.focus({ direction = "l"/"r"/"u"/"d" })` |
| `movewindow, l/r/u/d` | `hl.dsp.window.move({ direction = "l"/"r"/"u"/"d" })` |
| `workspace, N` | `hl.dsp.focus({ workspace = N })` |
| `workspace, e+1/e-1` | `hl.dsp.focus({ workspace = "e+1"/"e-1" })` |
| `movetoworkspace, N` | `hl.dsp.window.move({ workspace = N })` |
| `movetoworkspace, special:X` | `hl.dsp.window.move({ workspace = "special:X" })` |
| `togglespecialworkspace, X` | `hl.dsp.workspace.toggle_special("X")` |
| `resizeactive, W H` | `hl.dsp.window.resize({ x = W; y = H; relative = true; })` |
| `exit` | `hl.dsp.exit()` |
| `exec, CMD` | `hl.dsp.exec_cmd("CMD")` |

### Key-expression rewriting

hyprlang `MODS, KEY, disp, args` → `hl.bind(<key-expr>, <dispatcher>, <opts?>)`:
- `$mainMod, Return` → `lua ''mod .. " + Return"''`
- `$mainMod SHIFT, F` → `lua ''mod .. " + SHIFT + F"''`
- `$mainMod ALT, L` → `lua ''mod .. " + ALT + L"''`
- `, Print` (no mod) → `lua "Print"` (a plain Nix string also works; key has no mod)
- `$mainMod, mouse_down` → `lua ''mod .. " + mouse_down"''`

Keynames are preserved verbatim from the current config (`Return`, `Space`,
`minus`, `Left/Right/Up/Down`, `Print`, `XF86AudioMute`, …). Hyprland's
keybind parser accepts these identically in the lua DSL.

### Flag preservation

| current key | flags | new |
|---|---|---|
| `bind` (plain) | none | `bind`, no opts |
| `binde` (resize, volume, brightness) | repeating | `bind` + `{ repeating = true; }` |
| `bindm` (mouse drag/resize) | mouse | `bind` + `{ mouse = true; }` |

The current config uses `binde` (NOT `bindle`), so volume/brightness/resize
binds are **not** locked — that behavior is preserved (no `locked = true`).
Mute/micmute keys are plain `bind` (no flags), also preserved.

## Sections that stay untouched

- `services.hypridle`, `programs.hyprlock`, `services.gammastep` — separate
  HM modules, no lua form.
- `xdg.portal.config.hyprland.default`.
- `wayland.windowManager.hyprland.{systemd.enable, enable, package = null}`.

## Header comment

The top comment (lines 1–27) currently justifies the `configType = "hyprlang"`
pin. It will be rewritten to document the lua migration: why `configType` is
now `"lua"`, the `mod` local convention, the `_args`/`mkLuaInline` shape, and
the resolved `SUPER+SHIFT+S` conflict.

## Verification

1. `just nix-lint` → `nix flake check --no-build` (eval/type errors).
2. Inspect the generated lua:
   `nix eval --raw .#nixosConfigurations.tokyonight.config.home-manager.users.matus.xdg.configFile.\"hypr/hyprland.lua\".text`
   — confirm well-formed `hl.*` calls and semantic equivalence to the old conf.
3. (Optional, heavy) full closure build:
   `nix build .#nixosConfigurations.tokyonight.config.system.build.toplevel`.

No Rust, no `cargo`, no `tests/` changes — out of scope.

## Risks (low)

- **`"tap-to-click"` and other dashed field names** in `input.touchpad`:
  `lib.generators.toLua` emits `["tap-to-click"] = true` (quoted-bracket form).
  Hyprland's lua config reads table keys as field names, so this should map
  to the hyprlang `tap-to-click` field. Not explicitly exercised by the HM
  example; confirm via the `nix eval` output in verification.
- **`blur.new_optimizations`, `shadow.color = "rgba(…)"` (string vs numeric):**
  the official example uses `color = 0xee1a1a1a` (numeric) and omits
  `new_optimizations`. Hyprland accepts `rgba(…)` strings and string-keyed
  fields, so the current values should pass through. Confirm via `nix eval`.
- **Keyname case** (`Left` vs `left`): Hyprland's parser is case-insensitive
  for keynames; preserving the current `Left/Right/Up/Down` is safe.