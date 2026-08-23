# Phase 1: Single-Source Palette File Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `rust/palette.json` as the single Tokyo Night source of truth for beamenu's three hardcoded palette copies, and fix the bug where the Nix module never emits the `theme.canvas` key beamenu-canvas reads.

**Architecture:** One JSON file (`rust/palette.json`) is read at build time by Nix (`builtins.fromJSON (builtins.readFile …)`) and compiled into both Rust crates (`include_str!` + serde into a `LazyLock<Palette>`). Nix remains the configured path (it renders `config.json`, deriving accent slots from `programs.beamenu.accent`); the Rust `Default` impls become fallbacks derived from the same file. Both Rust derivations in `flake/packages.nix` widen their `src` with `lib.fileset.toSource` so the file — which sits above both crate dirs — reaches the sandbox.

**Tech Stack:** Rust 2021 (serde, `std::sync::LazyLock`), Nix flakes (`lib.fileset`, `buildRustPackage` + `sourceRoot`), Nix eval-only checks in `flake/checks.nix`.

**Spec:** docs/superpowers/specs/2026-08-23-system-palette-single-source-design.md

## Global Constraints

- Base colours in `palette.json` are 6-digit `#RRGGBB`; alpha is applied per consumer at the seam (bemenu gets `#RRGGBBAA` concatenated in Nix/Rust; the canvas gets `#RRGGBB` and applies alpha in CSS).
- The palette IS Tokyo Night: this deliberately reverts commit `573799b`'s "binding design palette" values for beamenu/beamenu-canvas defaults.
- No inline `#[cfg(test)]` tests — Rust tests go in each crate's `tests/` directory only.
- Comments: `//!` top-level and `///` per-symbol only; inline `//` only for genuine subtlety.
- `git add` every new/changed file BEFORE any `nix build`/`nix eval` — flake builds copy only git-tracked files (silently missing otherwise).
- Every `nix` eval/build command needs `--impure` (`nix/settings.nix` is a symlink to `/var/lib/dots/settings.nix`); the "Git tree … is dirty" warning is normal.
- `rustfmt` is not on ambient PATH: format with `nix shell nixpkgs#rustfmt -c cargo fmt --all` inside each crate dir.
- Local `cargo test` for `rust/beamenu` needs `PKG_CONFIG_PATH` pointing at a built `beamenu-view`; for `rust/beamenu-canvas` run under `nix-shell -p pkg-config gtk4 webkitgtk_6_0 gtk4-layer-shell` (both forms are expected to work but were NOT executed while planning — confirm before relying on them).
- `nix run .#nix-lint` and `nix flake check` die at the pre-existing broken `abstracttui` reference — gate with the explicit per-check/per-package builds given in Task 5 instead.
- Commit messages: repo style (`feat: …` lowercase), NO Co-Authored-By, NO session links.
- Never test against the live Hyprland session; nothing in this phase needs a live compositor at all.
- The fileset/`sourceRoot` form was verified on 2026-08-23 at the MECHANISM level only: `lib.fileset.toSource` was built in isolation and confirmed to (a) name its store path `source`, hence `sourceRoot = "source/beamenu"`, and (b) place the crate dir and the sibling JSON side by side, so `include_str!("../../palette.json")` from `beamenu/src/config.rs` resolves. A full `nix build --impure .#beamenu` has NOT been run — Task 1 must run it and treat a failure as a real finding, not a typo.

---

### Task 1: `rust/palette.json` + widened Rust `src` filesets + `palette-eval` check

**Files:**
- Create: `rust/palette.json`
- Modify: `flake/packages.nix` (beamenu drv lines 48–56, beamenu-canvas drv lines 63–78)
- Test: `flake/checks.nix` (append new `palette-eval` attr before the closing `}` at line 248)

**Interfaces:**
- Consumes: nothing new.
- Produces: `rust/palette.json` with top-level keys `colors` (16 slots), `accentFallback: "#7aa2f7"`, `alpha {panel, heading, opaque}`, `fonts {ui, mono, size, canvasUi, canvasMono}`, `beamenu {lines, widthFactor, iconSize, lineHeight, searchHeight, radius}`; `packages.${system}.beamenu.src` and `packages.${system}.beamenu-canvas.src` become fileset store paths whose root is `rust/` (so `${src}/palette.json` exists); `checks.${system}.palette-eval`.

- [ ] **Step 1: Create the palette file** — write `rust/palette.json` exactly as the spec gives it:

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

- [ ] **Step 2: Write the failing check** — append to `flake/checks.nix`, immediately before the final closing `}` (currently line 248):

```nix
  # rust/palette.json is the single source of truth for the system palette
  # (see docs/superpowers/specs/2026-08-23-system-palette-single-source-design.md).
  # It must parse with the schema both sides read, and it must reach BOTH
  # Rust builds' store src: each crate compiles it in via
  # include_str!("../../palette.json"), which resolves to <src root>/palette.json
  # only when the src fileset is rooted at rust/ rather than the crate dir.
  palette-eval =
    let
      palette = builtins.fromJSON (builtins.readFile ../rust/palette.json);
      beamenuSrc = self.packages.${system}.beamenu.src;
      canvasSrc = self.packages.${system}.beamenu-canvas.src;
    in
    assert builtins.pathExists "${beamenuSrc}/palette.json";
    assert builtins.pathExists "${canvasSrc}/palette.json";
    assert builtins.pathExists "${beamenuSrc}/beamenu/Cargo.lock";
    assert builtins.pathExists "${canvasSrc}/beamenu-canvas/Cargo.lock";
    assert palette.colors.bg == "#1a1b26";
    assert palette.colors.bgDarker == "#15161e";
    assert palette.accentFallback == "#7aa2f7";
    assert palette.alpha == { panel = "f2"; heading = "ee"; opaque = "ff"; };
    assert palette.fonts.canvasUi == "Manrope";
    assert palette.beamenu.lines == 9;
    pkgs.writeText "palette-eval-ok" palette.accentFallback;
```

- [ ] **Step 3: Run the check to verify it fails**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
git add rust/palette.json flake/checks.nix
nix build --impure .#checks.x86_64-linux.palette-eval
```

Expected failure: `error: … assertion '(builtins.pathExists "${beamenuSrc}/palette.json")' failed` (the un-widened `src = ../rust/beamenu` store path has no `palette.json`).

- [ ] **Step 4: Widen both derivations** — in `flake/packages.nix`, replace line 51 (`src = ../rust/beamenu;`) with:

```nix
    src = pkgs.lib.fileset.toSource {
      root = ../rust;
      fileset = pkgs.lib.fileset.unions [
        ../rust/beamenu
        ../rust/palette.json
      ];
    };
    sourceRoot = "source/beamenu";
```

and replace line 66 (`src = ../rust/beamenu-canvas;`) with:

```nix
    src = pkgs.lib.fileset.toSource {
      root = ../rust;
      fileset = pkgs.lib.fileset.unions [
        ../rust/beamenu-canvas
        ../rust/palette.json
      ];
    };
    sourceRoot = "source/beamenu-canvas";
```

Both `cargoLock.lockFile` lines (52 and 67) stay exactly as they are — they are eval-time paths, unaffected by the src widening.

- [ ] **Step 5: Run the check and both REAL builds to verify** (the spec flags packaging as the least certain part; the beamenu form was already verified in this worktree, the canvas build is the remaining confirmation):

```bash
git add flake/packages.nix
nix build --impure .#checks.x86_64-linux.palette-eval
nix build --impure .#beamenu --no-link
nix build --impure .#beamenu-canvas --no-link
```

Expected: the check builds (`palette-eval-ok` in the store), and both packages compile AND pass their `checkPhase` (`buildRustPackage` runs `cargo test` by default). If (and only if) `sourceRoot` trips the canvas build with a "Cargo.lock not found"-style error, the fallback is `cargoRoot = "beamenu-canvas";` + `buildAndTestSubdir = "beamenu-canvas";` in place of `sourceRoot` — but the beamenu build already succeeded with `sourceRoot`, so this is not expected.

- [ ] **Step 6: Commit**:

```bash
git commit -m "feat: single-source system palette file, widen rust src filesets

rust/palette.json (Tokyo Night neutrals + ramp, fonts, beamenu metrics,
accent fallback) is read by Nix via builtins.fromJSON and compiled into
the Rust crates via include_str!. Both beamenu derivations move to
lib.fileset.toSource rooted at rust/ so the file is in the store src;
cargoLock.lockFile stays an eval-time path. palette-eval gates the
schema and the src layout."
```

---

### Task 2: beamenu reads the palette — `palette` module + `Theme`/`Config` defaults redirect

**Files:**
- Create: `rust/beamenu/src/palette.rs`
- Modify: `rust/beamenu/src/lib.rs` (module list, lines 13–21), `rust/beamenu/src/config.rs` (lines 35–61: `default_accent` + `impl Default for Theme`; lines 96–113: metric `default_*` fns)
- Test: create `rust/beamenu/tests/palette.rs`

**Interfaces:**
- Consumes: `rust/palette.json` (Task 1), serde/serde_json (already in `Cargo.toml`).
- Produces: `pub static beamenu::palette::PALETTE: LazyLock<Palette>`; `pub struct Palette { colors: Colors, accent_fallback: String, alpha: Alpha, fonts: Fonts, beamenu: BeamenuMetrics }` (all fields `pub`, camelCase-renamed serde); `pub struct Colors` (16 `String` slots `bg, bg_dark, bg_darker, fg, fg_dark, muted, border, selection, blue, cyan, green, magenta, red, yellow, orange, dim`); `pub struct Alpha { panel: String, heading: String, opaque: String }`; `pub struct Fonts { ui: String, mono: String, size: u32, canvas_ui: String, canvas_mono: String }`; `pub struct BeamenuMetrics { lines: u32, width_factor: f32, icon_size: u32, line_height: u32, search_height: u32, radius: u32 }`; `pub fn accent_slots(accent: &str) -> (String, String)` returning `(selected_background, heading)`. `Theme::default()`/`Config::default()` semantics unchanged in shape, values now Tokyo Night.

- [ ] **Step 1: Write the failing test** — create `rust/beamenu/tests/palette.rs`:

```rust
//! The compiled-in palette: `rust/palette.json` parsed once, and the theme
//! defaults `src/config.rs` derives from it. The eight launcher slots must
//! resolve from the palette, and a non-default accent must move both
//! accent-derived slots (`selected_background`, `heading`) with it.

use beamenu::config::{Config, Theme};
use beamenu::palette::{accent_slots, PALETTE};

#[test]
fn palette_json_parses_to_tokyo_night() {
    assert_eq!(PALETTE.colors.bg, "#1a1b26");
    assert_eq!(PALETTE.colors.bg_dark, "#1f2335");
    assert_eq!(PALETTE.colors.bg_darker, "#15161e");
    assert_eq!(PALETTE.colors.fg, "#c0caf5");
    assert_eq!(PALETTE.colors.muted, "#737aa2");
    assert_eq!(PALETTE.colors.border, "#414868");
    assert_eq!(PALETTE.colors.selection, "#3b4261");
    assert_eq!(PALETTE.accent_fallback, "#7aa2f7");
    assert_eq!(PALETTE.alpha.panel, "f2");
    assert_eq!(PALETTE.alpha.heading, "ee");
    assert_eq!(PALETTE.alpha.opaque, "ff");
    assert_eq!(PALETTE.fonts.ui, "Lilex Nerd Font");
    assert_eq!(PALETTE.fonts.size, 12);
}

#[test]
fn theme_default_resolves_every_slot_from_the_palette() {
    let theme = Theme::default();
    assert_eq!(theme.background, "#1a1b26f2");
    assert_eq!(theme.foreground, "#c0caf5ff");
    assert_eq!(theme.muted, "#737aa2ff");
    assert_eq!(theme.selected_background, "#7aa2f7ff");
    assert_eq!(theme.selected_foreground, "#15161eff");
    assert_eq!(theme.border, "#414868ff");
    assert_eq!(theme.heading, "#7aa2f7ee");
    assert_eq!(theme.font, "Lilex Nerd Font 12");
    assert_eq!(theme.accent, "#7aa2f7");
}

#[test]
fn a_non_default_accent_moves_both_derived_slots() {
    let (selected_background, heading) = accent_slots("#8fb8f0");
    assert_eq!(selected_background, "#8fb8f0ff");
    assert_eq!(heading, "#8fb8f0ee");
    let stock = Theme::default();
    assert_ne!(selected_background, stock.selected_background);
    assert_ne!(heading, stock.heading);
}

#[test]
fn config_metric_defaults_come_from_the_palette() {
    let config = Config::default();
    assert_eq!(config.lines, PALETTE.beamenu.lines);
    assert_eq!(config.icon_size, PALETTE.beamenu.icon_size);
    assert_eq!(config.line_height, PALETTE.beamenu.line_height);
    assert_eq!(config.search_height, PALETTE.beamenu.search_height);
    assert_eq!(config.radius, PALETTE.beamenu.radius);
    assert!((config.width_factor - PALETTE.beamenu.width_factor).abs() < f32::EPSILON);
}
```

- [ ] **Step 2: Run test to verify it fails**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
nix build --impure .#beamenu-view -o /tmp/beamenu-view-pc
cd rust/beamenu
PKG_CONFIG_PATH=/tmp/beamenu-view-pc/lib/pkgconfig cargo test --test palette
```

Expected failure: `error[E0432]: unresolved import beamenu::palette` (the module does not exist yet).

- [ ] **Step 3: Write the palette module** — create `rust/beamenu/src/palette.rs`:

```rust
//! The system palette, compiled in from `rust/palette.json` — the same file
//! `nix/home/beamenu.nix` reads with `builtins.fromJSON`, so the Nix-rendered
//! config and these Rust fallbacks can never drift apart.
//!
//! Base colours are 6-digit `#RRGGBB`; alpha is applied per consumer at the
//! seam via [`Alpha`]'s two-hex-digit suffixes, because bemenu wants
//! `#RRGGBBAA` while other surfaces re-apply opacity themselves.

use std::sync::LazyLock;

use serde::Deserialize;

/// Raw bytes of `rust/palette.json`; the path climbs out of the crate dir,
/// which is why flake/packages.nix roots the src fileset at `rust/`.
const RAW: &str = include_str!("../../palette.json");

/// The palette, parsed once on first use. The file is committed and gated by
/// the `palette-eval` flake check, so a parse failure is a build bug.
pub static PALETTE: LazyLock<Palette> = LazyLock::new(|| {
    serde_json::from_str(RAW).expect("rust/palette.json is valid; palette-eval gates it")
});

/// Everything `rust/palette.json` declares.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Palette {
    pub colors: Colors,
    /// Accent used before a wallpaper-derived accent exists.
    pub accent_fallback: String,
    pub alpha: Alpha,
    pub fonts: Fonts,
    pub beamenu: BeamenuMetrics,
}

/// Tokyo Night neutrals and ramp, 6-digit `#RRGGBB`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Colors {
    pub bg: String,
    pub bg_dark: String,
    pub bg_darker: String,
    pub fg: String,
    pub fg_dark: String,
    pub muted: String,
    pub border: String,
    pub selection: String,
    pub blue: String,
    pub cyan: String,
    pub green: String,
    pub magenta: String,
    pub red: String,
    pub yellow: String,
    pub orange: String,
    pub dim: String,
}

/// Two-hex-digit alpha suffixes appended to a base colour at the seam.
#[derive(Debug, Clone, Deserialize)]
pub struct Alpha {
    pub panel: String,
    pub heading: String,
    pub opaque: String,
}

/// Font roles. `canvas_ui`/`canvas_mono` name beamenu-canvas's deliberately
/// distinct typography; the divergence is a declared choice, not a second
/// hardcoded list.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fonts {
    pub ui: String,
    pub mono: String,
    pub size: u32,
    pub canvas_ui: String,
    pub canvas_mono: String,
}

/// beamenu's layout metrics — app-scoped, but duplicated between the Nix
/// options and the serde defaults in exactly the way the colours were, so
/// they live in the same file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BeamenuMetrics {
    pub lines: u32,
    pub width_factor: f32,
    pub icon_size: u32,
    pub line_height: u32,
    pub search_height: u32,
    pub radius: u32,
}

/// The two theme slots derived from an accent: `selected_background`
/// (accent + opaque alpha) and `heading` (accent + heading alpha), in that
/// order. The same concatenation lives in `nix/home/beamenu.nix` for the
/// configured path — serde defaults cannot read sibling fields, so the rule
/// exists once per side and both sides are tested.
#[must_use]
pub fn accent_slots(accent: &str) -> (String, String) {
    (
        format!("{accent}{}", PALETTE.alpha.opaque),
        format!("{accent}{}", PALETTE.alpha.heading),
    )
}
```

Then in `rust/beamenu/src/lib.rs`, insert `pub mod palette;` into the module list between `pub mod item;` (line 18) and `pub mod providers;` (line 19).

- [ ] **Step 4: Redirect the config defaults** — in `rust/beamenu/src/config.rs`, add `use crate::palette::{accent_slots, PALETTE};` after the existing `use serde::…` (line 9), then replace lines 35–61 (`fn default_accent` through the end of `impl Default for Theme`) with:

```rust
fn default_accent() -> String {
    PALETTE.accent_fallback.clone()
}

impl Default for Theme {
    /// Every slot resolved from `rust/palette.json` (Tokyo Night):
    /// panel `bg` + panel alpha, text `fg`, `muted`, `border`, and the two
    /// accent-derived slots from [`accent_slots`] over `accentFallback`.
    /// Text drawn on the accent fill uses `bgDarker`, keeping the
    /// dark-on-accent contrast the launcher always had.
    ///
    /// This is the fallback for a missing or unparseable config.json, not
    /// the configured path — `nix/home/beamenu.nix` renders the same file
    /// into config.json, so the two can only drift if the palette schema
    /// itself changes.
    fn default() -> Self {
        let p = &*PALETTE;
        let (selected_background, heading) = accent_slots(&p.accent_fallback);
        Self {
            background: format!("{}{}", p.colors.bg, p.alpha.panel),
            foreground: format!("{}{}", p.colors.fg, p.alpha.opaque),
            muted: format!("{}{}", p.colors.muted, p.alpha.opaque),
            selected_background,
            selected_foreground: format!("{}{}", p.colors.bg_darker, p.alpha.opaque),
            border: format!("{}{}", p.colors.border, p.alpha.opaque),
            heading,
            font: format!("{} {}", p.fonts.ui, p.fonts.size),
            accent: default_accent(),
        }
    }
}
```

and replace the six metric fns at lines 96–113 with:

```rust
fn default_lines() -> u32 {
    PALETTE.beamenu.lines
}
fn default_width_factor() -> f32 {
    PALETTE.beamenu.width_factor
}
fn default_icon_size() -> u32 {
    PALETTE.beamenu.icon_size
}
fn default_line_height() -> u32 {
    PALETTE.beamenu.line_height
}
fn default_search_height() -> u32 {
    PALETTE.beamenu.search_height
}
fn default_radius() -> u32 {
    PALETTE.beamenu.radius
}
```

- [ ] **Step 5: Run tests to verify they pass** (full suite, not just the new file — `Theme::default()` values changed):

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/beamenu
PKG_CONFIG_PATH=/tmp/beamenu-view-pc/lib/pkgconfig cargo test
nix shell nixpkgs#rustfmt -c cargo fmt --all
PKG_CONFIG_PATH=/tmp/beamenu-view-pc/lib/pkgconfig cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic
```

Expected: all tests pass, clippy clean. Then confirm the sandbox build:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
git add rust/beamenu
nix build --impure .#beamenu --no-link
```

- [ ] **Step 6: Commit**:

```bash
git commit -m "feat: beamenu theme and metric defaults from palette.json

src/palette.rs compiles rust/palette.json in (include_str! + serde +
LazyLock); Theme::default and the metric serde defaults resolve from it,
replacing the binding-design literals with Tokyo Night. accent_slots()
carries the accent -> selected_background/heading derivation so a
non-default accent moves both slots, mirrored by nix/home/beamenu.nix."
```

---

### Task 3: beamenu-canvas reads the palette — Tokyo Night defaults, `tests/theme.rs` as the regression gate

**Files:**
- Create: `rust/beamenu-canvas/src/palette.rs`
- Modify: `rust/beamenu-canvas/src/lib.rs` (module list, lines 11–20), `rust/beamenu-canvas/src/theme.rs` (lines 36–69: the ten `default_*` fns and `PRIMARY_BUTTON_TEXT`), `rust/beamenu-canvas/src/config.rs` (lines 30–34: `default_width_factor`)
- Test: rewrite `rust/beamenu-canvas/tests/theme.rs` (all eleven old literal assertions change in this same task — they are the regression gate)

**Interfaces:**
- Consumes: `rust/palette.json` (Task 1).
- Produces: `pub static beamenu_canvas::palette::PALETTE: LazyLock<Palette>` where `pub struct Palette { colors: Colors, accent_fallback: String, fonts: Fonts, beamenu: Metrics }`, `pub struct Colors { bg, bg_dark, bg_darker, fg, muted, border, selection: String }`, `pub struct Fonts { canvas_ui: String, canvas_mono: String }`, `pub struct Metrics { width_factor: f32 }` (the subset this crate reads; serde ignores the rest of the file). `CanvasTheme::default()` becomes Tokyo Night for free, since `Default` is `serde_json::from_str("{}")` over the redirected `default_*` fns. `PRIMARY_BUTTON_TEXT` becomes `"#15161e"` (palette `bgDarker`), tied to the palette by test. Canvas slot mapping: `bg→colors.bg`, `panel_gradient_start→colors.bgDark`, `panel_gradient_end→colors.bg`, `border→colors.selection` (the hairline), `border_strong→colors.border` (the stronger of Tokyo Night's pair), `text→colors.fg`, `muted→colors.muted`, `accent→accentFallback`.

- [ ] **Step 1: Write the failing test** — replace `rust/beamenu-canvas/tests/theme.rs` in full:

```rust
//! Design tokens: the Tokyo Night defaults resolved from `rust/palette.json`,
//! partial `theme.canvas` overrides, and the generated stylesheet.

use beamenu_canvas::palette::PALETTE;
use beamenu_canvas::theme::{hex_to_rgba, stylesheet, CanvasTheme, PRIMARY_BUTTON_TEXT};

#[test]
fn defaults_match_the_tokyo_night_palette() {
    let theme = CanvasTheme::default();
    assert_eq!(theme.font_ui, "Manrope");
    assert_eq!(theme.font_mono, "JetBrains Mono");
    assert_eq!(theme.bg, "#1a1b26");
    assert_eq!(theme.panel_gradient_start, "#1f2335");
    assert_eq!(theme.panel_gradient_end, "#1a1b26");
    assert_eq!(theme.border, "#3b4261");
    assert_eq!(theme.border_strong, "#414868");
    assert_eq!(theme.text, "#c0caf5");
    assert_eq!(theme.muted, "#737aa2");
    assert_eq!(theme.accent, "#7aa2f7");
    assert_eq!(PRIMARY_BUTTON_TEXT, "#15161e");
}

#[test]
fn defaults_are_the_palette_file_verbatim() {
    let theme = CanvasTheme::default();
    assert_eq!(theme.font_ui, PALETTE.fonts.canvas_ui);
    assert_eq!(theme.font_mono, PALETTE.fonts.canvas_mono);
    assert_eq!(theme.bg, PALETTE.colors.bg);
    assert_eq!(theme.panel_gradient_start, PALETTE.colors.bg_dark);
    assert_eq!(theme.panel_gradient_end, PALETTE.colors.bg);
    assert_eq!(theme.border, PALETTE.colors.selection);
    assert_eq!(theme.border_strong, PALETTE.colors.border);
    assert_eq!(theme.text, PALETTE.colors.fg);
    assert_eq!(theme.muted, PALETTE.colors.muted);
    assert_eq!(theme.accent, PALETTE.accent_fallback);
    assert_eq!(PRIMARY_BUTTON_TEXT, PALETTE.colors.bg_darker);
}

#[test]
fn deserializes_from_empty_object_using_defaults() {
    let theme: CanvasTheme = serde_json::from_str("{}").expect("defaults apply");
    assert_eq!(theme, CanvasTheme::default());
}

#[test]
fn partial_override_keeps_the_rest_at_default() {
    let theme: CanvasTheme =
        serde_json::from_str(r##"{"accent": "#ff00ff"}"##).expect("partial theme parses");
    assert_eq!(theme.accent, "#ff00ff");
    assert_eq!(theme.font_ui, "Manrope");
    assert_eq!(theme.bg, "#1a1b26");
}

#[test]
fn hex_to_rgba_converts_six_digit_hex() {
    assert_eq!(hex_to_rgba("#7fd6c2", 0.2), "rgba(127, 214, 194, 0.2)");
}

#[test]
fn hex_to_rgba_ignores_trailing_alpha_channel() {
    assert_eq!(hex_to_rgba("#7fd6c2ff", 0.2), "rgba(127, 214, 194, 0.2)");
}

#[test]
fn hex_to_rgba_falls_back_to_black_on_malformed_input() {
    assert_eq!(hex_to_rgba("not-a-colour", 0.5), "rgba(0, 0, 0, 0.5)");
}

#[test]
fn stylesheet_embeds_the_focus_ring_at_binding_alpha() {
    let theme = CanvasTheme::default();
    let css = stylesheet(&theme);
    assert!(css.contains("rgba(122, 162, 247, 0.2)"));
}

#[test]
fn stylesheet_embeds_every_token() {
    let theme = CanvasTheme::default();
    let css = stylesheet(&theme);
    assert!(css.contains("Manrope"));
    assert!(css.contains("JetBrains Mono"));
    assert!(css.contains("#1a1b26"));
    assert!(css.contains("#1f2335"));
    assert!(css.contains("#3b4261"));
    assert!(css.contains("#414868"));
    assert!(css.contains("#c0caf5"));
    assert!(css.contains("#737aa2"));
    assert!(css.contains("#7aa2f7"));
    assert!(css.contains(PRIMARY_BUTTON_TEXT));
}

#[test]
fn stylesheet_reflects_a_custom_accent() {
    let mut theme = CanvasTheme::default();
    theme.accent = "#ff8800".to_string();
    let css = stylesheet(&theme);
    assert!(css.contains("#ff8800"));
    assert!(!css.contains("#7aa2f7"));
}
```

(`hex_to_rgba` keeps its `#7fd6c2` inputs — it is a pure conversion function; those are arbitrary test vectors, not palette assertions. The focus ring for accent `#7aa2f7` is `rgba(122, 162, 247, 0.2)`: 0x7a=122, 0xa2=162, 0xf7=247.)

- [ ] **Step 2: Run test to verify it fails**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/beamenu-canvas
nix-shell -p pkg-config gtk4 webkitgtk_6_0 gtk4-layer-shell --run "cargo test --test theme"
```

Expected failure: `error[E0433]: failed to resolve: could not find `palette` in `beamenu_canvas`` (module doesn't exist yet).

- [ ] **Step 3: Write the canvas palette module** — create `rust/beamenu-canvas/src/palette.rs`:

```rust
//! The subset of `rust/palette.json` this crate reads, compiled in via
//! `include_str!` — the same file `nix/home/beamenu.nix` reads with
//! `builtins.fromJSON` and `rust/beamenu/src/palette.rs` carries in full.
//! A trimmed duplicate rather than a dependency, for the same reason
//! `src/config.rs` duplicates the loader: the two crates stay unlinked.

use std::sync::LazyLock;

use serde::Deserialize;

/// Raw bytes of `rust/palette.json`; flake/packages.nix roots the src
/// fileset at `rust/` so this path resolves inside the sandbox too.
const RAW: &str = include_str!("../../palette.json");

/// Parsed once on first use; the committed file is gated by the
/// `palette-eval` flake check, so a parse failure is a build bug.
pub static PALETTE: LazyLock<Palette> = LazyLock::new(|| {
    serde_json::from_str(RAW).expect("rust/palette.json is valid; palette-eval gates it")
});

/// The palette keys the canvas reads; serde ignores the rest of the file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Palette {
    pub colors: Colors,
    /// Accent used before a wallpaper-derived accent exists.
    pub accent_fallback: String,
    pub fonts: Fonts,
    pub beamenu: Metrics,
}

/// Neutral slots, 6-digit `#RRGGBB` — the canvas applies alpha in CSS.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Colors {
    pub bg: String,
    pub bg_dark: String,
    pub bg_darker: String,
    pub fg: String,
    pub muted: String,
    pub border: String,
    pub selection: String,
}

/// The canvas's deliberately distinct typography roles.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fonts {
    pub canvas_ui: String,
    pub canvas_mono: String,
}

/// Launcher metrics shared with `rust/beamenu`; only `widthFactor` is read
/// here, to size the layer-shell surface like the launcher panel.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub width_factor: f32,
}
```

Then in `rust/beamenu-canvas/src/lib.rs`, insert `pub mod palette;` between `pub mod markdown;` (line 17) and `pub mod rpc;` (line 18).

- [ ] **Step 4: Redirect the theme and config defaults** — in `rust/beamenu-canvas/src/theme.rs`, add `use crate::palette::PALETTE;` after the `use serde::…` (line 10); replace lines 36–65 (the ten `default_*` fns) with:

```rust
fn default_font_ui() -> String {
    PALETTE.fonts.canvas_ui.clone()
}
fn default_font_mono() -> String {
    PALETTE.fonts.canvas_mono.clone()
}
fn default_bg() -> String {
    PALETTE.colors.bg.clone()
}
fn default_panel_start() -> String {
    PALETTE.colors.bg_dark.clone()
}
fn default_panel_end() -> String {
    PALETTE.colors.bg.clone()
}
/// Hairline border: Tokyo Night's `selection`, the dimmer of its pair —
/// `border_strong` below takes the brighter `border` slot.
fn default_border() -> String {
    PALETTE.colors.selection.clone()
}
fn default_border_strong() -> String {
    PALETTE.colors.border.clone()
}
fn default_text() -> String {
    PALETTE.colors.fg.clone()
}
fn default_muted() -> String {
    PALETTE.colors.muted.clone()
}
fn default_accent() -> String {
    PALETTE.accent_fallback.clone()
}
```

replace lines 67–69 (the `PRIMARY_BUTTON_TEXT` doc + const) with:

```rust
/// Primary button text colour — fixed, not derived from `accent`, so the
/// button stays high-contrast whatever `accent` is configured to. Mirrors
/// the palette file's `colors.bgDarker`; a const cannot read the LazyLock,
/// so `tests/theme.rs` pins the two together instead.
pub const PRIMARY_BUTTON_TEXT: &str = "#15161e";
```

and update the crate-doc first paragraph (lines 1–8) to say the defaults come from `rust/palette.json` (Tokyo Night) rather than "the binding design values from the task brief". In `rust/beamenu-canvas/src/config.rs`, replace lines 30–34 (`default_width_factor` and its comment) with:

```rust
use crate::palette::PALETTE;

/// The same `beamenu.widthFactor` slot of `rust/palette.json` that
/// `rust/beamenu/src/config.rs` and `nix/home/beamenu.nix` read.
fn default_width_factor() -> f32 {
    PALETTE.beamenu.width_factor
}
```

(with the `use` line moved up beside the existing `use crate::theme::CanvasTheme;` at line 14).

- [ ] **Step 5: Run tests to verify they pass** (full suite — `component.rs`/`rpc.rs` tests exercise the stylesheet indirectly):

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/beamenu-canvas
nix-shell -p pkg-config gtk4 webkitgtk_6_0 gtk4-layer-shell --run "cargo test"
nix shell nixpkgs#rustfmt -c cargo fmt --all
nix-shell -p pkg-config gtk4 webkitgtk_6_0 gtk4-layer-shell --run "cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic"
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
git add rust/beamenu-canvas
nix build --impure .#beamenu-canvas --no-link
```

(The final `nix build` can exceed 5 minutes — webkit6 bindings recompile in the sandbox; let it run.)

- [ ] **Step 6: Commit**:

```bash
git commit -m "feat: beamenu-canvas defaults from palette.json, tokyo night

src/palette.rs compiles the palette subset in; every CanvasTheme serde
default resolves from it, so Default (serde_json::from_str of {}) is
Tokyo Night for free. border maps to the selection slot and
border_strong to border, keeping the weak/strong pair ordered.
PRIMARY_BUTTON_TEXT mirrors colors.bgDarker, pinned by test.
tests/theme.rs literal assertions move to the Tokyo Night values as the
regression gate on the indirection."
```

---

### Task 4: `nix/home/beamenu.nix` reads the palette, emits `theme.canvas`, gated by the round-trip check

**Files:**
- Modify: `nix/home/beamenu.nix` (let block lines 27–59; option defaults at lines 90–142)
- Test: `flake/checks.nix` (append `beamenu-config-eval` after `palette-eval` from Task 1)

**Interfaces:**
- Consumes: `rust/palette.json`; `settings.username` (already bound at `flake/checks.nix:13`); `self.nixosConfigurations.tokyonight.config.home-manager.users.<username>` (home-manager is a NixOS module, `nix/modules/users.nix:102-131`).
- Produces: `config.json` whose `theme` gains a nested `canvas` object with exactly the ten `CanvasTheme` serde field names (`font_ui, font_mono, bg, panel_gradient_start, panel_gradient_end, border, border_strong, text, muted, accent`) — the high-severity bug fix (`theme.canvas` was read at `rust/beamenu-canvas/src/config.rs:19` but never written); `theme.selected_background`/`theme.heading`/`theme.canvas.accent` all derive from `cfg.accent`; `checks.${system}.beamenu-config-eval`.

- [ ] **Step 1: Write the failing round-trip check** — append to `flake/checks.nix` after `palette-eval`:

```nix
  # Round-trip: the Nix-rendered beamenu config.json must contain every key
  # its two Rust consumers read (rust/beamenu/src/config.rs and
  # rust/beamenu-canvas/src/{config,theme}.rs), and the accent-derived slots
  # must actually follow programs.beamenu.accent. theme.canvas missing was a
  # live bug — the sidecar silently rendered its compiled-in defaults — and
  # this check would have caught it at eval time.
  beamenu-config-eval =
    let
      palette = builtins.fromJSON (builtins.readFile ../rust/palette.json);
      hmUser =
        c: c.config.home-manager.users.${settings.username};
      rendered = builtins.fromJSON
        (hmUser { config = self.nixosConfigurations.tokyonight.config; })
        .xdg.configFile."beamenu/config.json".text;
      accented = self.nixosConfigurations.tokyonight.extendModules {
        modules = [
          { home-manager.users.${settings.username}.programs.beamenu.accent = "#8fb8f0"; }
        ];
      };
      renderedAccent = builtins.fromJSON
        (hmUser accented).xdg.configFile."beamenu/config.json".text;
      hasAll = attrs: keys: builtins.all (k: builtins.hasAttr k attrs) keys;
      launcherKeys = [
        "theme" "lines" "width_factor" "icon_size" "line_height"
        "search_height" "radius" "terminal" "file_manager" "disabled"
      ];
      launcherTheme = [
        "background" "foreground" "muted" "selected_background"
        "selected_foreground" "border" "heading" "font" "accent" "canvas"
      ];
      canvasTheme = [
        "font_ui" "font_mono" "bg" "panel_gradient_start" "panel_gradient_end"
        "border" "border_strong" "text" "muted" "accent"
      ];
    in
    assert hasAll rendered launcherKeys;
    assert hasAll rendered.theme launcherTheme;
    assert hasAll rendered.theme.canvas canvasTheme;
    assert rendered.theme.background == palette.colors.bg + palette.alpha.panel;
    assert rendered.theme.selected_background == palette.accentFallback + palette.alpha.opaque;
    assert rendered.theme.canvas.bg == palette.colors.bg;
    assert rendered.lines == palette.beamenu.lines;
    assert rendered.width_factor == palette.beamenu.widthFactor;
    assert renderedAccent.theme.selected_background == "#8fb8f0" + palette.alpha.opaque;
    assert renderedAccent.theme.heading == "#8fb8f0" + palette.alpha.heading;
    assert renderedAccent.theme.canvas.accent == "#8fb8f0";
    pkgs.writeText "beamenu-config-ok" "theme.canvas present, accent derived";
```

- [ ] **Step 2: Run the check to verify it fails**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
git add flake/checks.nix
nix build --impure .#checks.x86_64-linux.beamenu-config-eval
```

Expected failure: `assertion '(hasAll rendered.theme launcherTheme)' failed` (no `canvas` key in the current flat theme; the hardcoded `#0d1013f2` background would fail the value asserts right after it too).

- [ ] **Step 3: Rewrite the module's let block** — in `nix/home/beamenu.nix`, replace lines 27–59 (from `let` through the end of `configJson = { … };`) with:

```nix
let
  cfg = config.programs.beamenu;

  # The system palette — rust/palette.json is the single source of truth for
  # neutrals, fonts and the beamenu metrics. The Rust side compiles the same
  # file in (rust/beamenu/src/palette.rs, rust/beamenu-canvas/src/palette.rs);
  # this module is the configured path, the Rust Default impls the fallback.
  palette = builtins.fromJSON (builtins.readFile ../../rust/palette.json);
  inherit (palette) colors alpha;

  # bemenu wants #RRGGBBAA, so alpha is applied here at the seam; base values
  # stay 6-digit in the palette file. selected_background and heading derive
  # from cfg.accent, so programs.beamenu.accent moves every accent surface —
  # highlighted row, heading tint and the canvas accent — not just the
  # highlighted row. Text drawn on the accent fill is bgDarker (dark on
  # light-accent, as the launcher always had).
  theme = {
    background = colors.bg + alpha.panel;
    foreground = colors.fg + alpha.opaque;
    muted = colors.muted + alpha.opaque;
    selected_background = cfg.accent + alpha.opaque;
    selected_foreground = colors.bgDarker + alpha.opaque;
    border = colors.border + alpha.opaque;
    heading = cfg.accent + alpha.heading;
    font = "${palette.fonts.ui} ${toString palette.fonts.size}";
    accent = cfg.accent;
    # beamenu-canvas reads theme.canvas (rust/beamenu-canvas/src/config.rs);
    # this key was never emitted before, so the sidecar always rendered its
    # compiled-in defaults. Field names are CanvasTheme's serde names; values
    # stay 6-digit because the canvas applies alpha in CSS itself. border is
    # the hairline (selection slot), border_strong the brighter border slot.
    canvas = {
      font_ui = palette.fonts.canvasUi;
      font_mono = palette.fonts.canvasMono;
      bg = colors.bg;
      panel_gradient_start = colors.bgDark;
      panel_gradient_end = colors.bg;
      border = colors.selection;
      border_strong = colors.border;
      text = colors.fg;
      muted = colors.muted;
      accent = cfg.accent;
    };
  };

  # The Rust side reads snake_case; the Nix options are camelCase to match the
  # rest of this repo's option style, so rename on the way out.
  configJson = {
    inherit theme;
    lines = cfg.lines;
    width_factor = cfg.widthFactor;
    icon_size = cfg.iconSize;
    line_height = cfg.lineHeight;
    search_height = cfg.searchHeight;
    radius = cfg.radius;
    terminal = cfg.terminal;
    file_manager = cfg.fileManager;
    disabled = cfg.disabledProviders;
  };
```

- [ ] **Step 4: Redirect the option defaults** — in the same file, change exactly these defaults (option bodies otherwise untouched): `lines` (line 92) `default = palette.beamenu.lines;`, `widthFactor` (line 98) `default = palette.beamenu.widthFactor;`, `iconSize` (line 108) `default = palette.beamenu.iconSize;`, `lineHeight` (line 114) `default = palette.beamenu.lineHeight;`, `searchHeight` (line 120) `default = palette.beamenu.searchHeight;`, `radius` (line 126) `default = palette.beamenu.radius;`, and replace the whole `accent` option (lines 130–142) with:

```nix
    accent = lib.mkOption {
      type = lib.types.str;
      default = palette.accentFallback;
      example = "#7fd6c2";
      description = ''
        Accent colour for every accent surface: the highlighted result row,
        the active filter pill, the heading tint and the canvas accent —
        `selected_background`, `heading` and `theme.canvas.accent` all
        derive from it. Its own text is always the palette's darkest
        neutral, so alternates should stay light: `#7fd6c2` (teal),
        `#e0b083` (amber), `#c9a8f0` (violet).
      '';
    };
```

- [ ] **Step 5: Run the check to verify it passes**:

```bash
git add nix/home/beamenu.nix
nix build --impure .#checks.x86_64-linux.beamenu-config-eval
nix fmt -- flake/checks.nix flake/packages.nix nix/home/beamenu.nix
git add flake/checks.nix flake/packages.nix nix/home/beamenu.nix
nix build --impure .#checks.x86_64-linux.beamenu-config-eval
```

Expected: `beamenu-config-ok` builds (run twice around `nix fmt` so a formatter rewrite cannot un-verify the result).

- [ ] **Step 6: Commit**:

```bash
git commit -m "feat: derive beamenu config from palette.json, emit theme.canvas

nix/home/beamenu.nix builds its theme and option defaults from
rust/palette.json instead of a third hardcoded copy, and derives
selected_background, heading and the canvas accent from
programs.beamenu.accent — previously the accent only moved the
highlighted row. config.json now carries the nested theme.canvas object
beamenu-canvas reads; it was read but never written, so the sidecar
always rendered compiled-in defaults. beamenu-config-eval round-trips
the rendered file against every key both Rust consumers read."
```

---

### Task 5: Gate sweep — fmt, clippy pedantic, all builds and checks green

**Files:**
- Modify: none expected (fixups only if a gate fails)
- Test: everything below

**Interfaces:** Consumes all prior tasks; produces a clean tree at the Phase 1 exit state.

- [ ] **Step 1: Format both touched crates and the Nix files**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/beamenu
nix shell nixpkgs#rustfmt -c cargo fmt --all -- --check
cd ../beamenu-canvas
nix shell nixpkgs#rustfmt -c cargo fmt --all -- --check
cd ../..
nix fmt -- flake/checks.nix flake/packages.nix nix/home/beamenu.nix rust 2>/dev/null || nix fmt
git diff --exit-code
```

Expected: no diffs. If `--check` or `git diff` reports changes, drop `--check`, re-run, `git add -u`.

- [ ] **Step 2: Clippy pedantic on both crates**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/beamenu
PKG_CONFIG_PATH=/tmp/beamenu-view-pc/lib/pkgconfig cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic
cd ../beamenu-canvas
nix-shell -p pkg-config gtk4 webkitgtk_6_0 gtk4-layer-shell --run "cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic"
```

Expected: zero warnings (the pre-existing `pkg-config could not find bemenu` build-script warning in the beamenu crate is not clippy output and is expected outside the sandbox).

- [ ] **Step 3: Sandbox builds (run each crate's test suite in checkPhase) and all three touched eval surfaces**:

```bash
cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao
git add -A
nix build --impure .#beamenu .#beamenu-canvas --no-link
nix build --impure .#checks.x86_64-linux.palette-eval .#checks.x86_64-linux.beamenu-config-eval .#checks.x86_64-linux.settings-eval --no-link
```

Expected: all five build. (`nix run .#nix-lint` / `nix flake check` are NOT the gate here: both die at the pre-existing broken `abstracttui` reference, and nix-lint's cargo loop does not cover the beamenu crates at all — `flake/apps.nix:82-85`.)

- [ ] **Step 4: Confirm no stray palette literals survived** — the four files that carried the old palette must be the only ones that ever did, and must now carry none:

```bash
grep -rn "7fd6c2\|0d1013\|e6ebef\|5b6672\|1e252c\|08110e\|171c22\|262e36" --include="*.nix" nix/ flake/
grep -rn "7fd6c2\|0d1013\|e6ebef\|5b6672\|1e252c\|08110e\|171c22\|262e36" rust/beamenu/src rust/beamenu-canvas/src
```

Expected: first grep empty; second grep empty (the `#7fd6c2` occurrences remaining in `rust/beamenu-canvas/tests/theme.rs` are `hex_to_rgba` conversion vectors, deliberately kept, and are outside both grep scopes).

- [ ] **Step 5: Commit fixups only if the sweep changed anything**:

```bash
git diff --quiet && git diff --cached --quiet || git commit -am "chore: fmt/clippy fixups from the phase 1 gate sweep"
```
