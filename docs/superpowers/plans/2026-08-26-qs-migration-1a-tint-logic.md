# Quickshell Migration 1a: Tint Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Port `accent.rs` and `tint.rs`'s pure functions to JS under
QtTest, before any wallpaper pixel is drawn by the shell.
**Architecture:** Two JS modules with no QML surface, so all of it is
testable offscreen. `wallpaper-tui` still runs and still owns the wallpaper;
this plan only proves the replacement maths. Needs plan 0's `common/hls.js`.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
From `accent.rs`/`tint.rs`; reproduce exactly or the ported vectors break.
- 64x64 downsample, 16 hue bins, drop l outside [0.1,0.9] or s<0.2, win =
  largest saturation-weighted bin, ties to the LAST. All three shades come
  from that one mean hue at S=0.55, L=0.62/0.40/0.78.
- `ADWAITA_BLUE_HEXES` = #1c71d8 #438de6 #3584e4 #62a0ea #99c1f1 #afd4ff
- `KVANTUM_ACCENT_HEXES` = #8caaee #839edd #98b2ef, case-insensitive,
  7-char body only so trailing alpha survives.
- `drawImage` needs the URL string after `loadImage()`; an `Image` item
  draws transparent black and reports no error. Do not "simplify" it back.

---

### Task 1: The accent extractor
**Files:** create `qml/wallpaper/accent.js`, `tests/qml/tst_accent.qml`.
**Consumes** `common/hls.js`. **Produces** `accentFrom(pixels)`, taking an RGBA
`Uint8ClampedArray` in, `{accent, dark, light}` as `#rrggbb` out.
- [ ] **1** Record the oracle WITHOUT touching the live desktop: add a
      temporary `--dump-accent <path>` to wallpaper-tui that prints the
      extracted triple and exits. NEVER run `wallpaper-tui --output` — it
      applies the wallpaper AND retints GTK, Rofi, Kvantum and the icons
- [ ] **2** Assert the exact oracle against a 64x64 LOSSLESS PNG, where
      Rust's `thumbnail(64,64)` is a documented no-op and Canvas draws 1:1,
      so both pipelines see identical pixels. On a real photo the two
      scalers disagree and the accent drifts ~1/255 — see step 6
- [ ] **3** Run QtTest Expected: FAIL, `accentFrom` undefined
- [ ] **4** Port the bucket loop from `accent.rs`. QtTest Expected: PASS
- [ ] **6** Add cases that need no image at all, since `accentFrom` takes a
      pixel array: an all-black buffer falls back to `DEFAULT_ACCENT`; an
      exact cross-bin weight tie proves the `>=` last-wins tie-break; and
      buffers sitting on l=0.1, l=0.9 and s=0.2 pin the discard thresholds
- [ ] **7** Run QtTest Expected: PASS. Then assert the real 1920x1080 JPEG
      within +/-1 per channel, with the two scalers named as the reason
- [ ] **8** `git commit -m "read the wallpaper accent from a canvas"`

### Task 2: The tint writers
**Files:** create `qml/wallpaper/tint.js`, `tests/qml/tst_tint.qml`.
**Produces** ports of `tint.rs`'s writers. Their real signatures are NOT all
string->string; read them before writing anything:
`rofiRasiText(base, accent, dark)`; `gtkCss(accent, dark, light, version)`,
which GENERATES css rather than rewriting a base; `recolorKvantumText(text,
accent, dark, light)`, mapping the three Kvantum hexes to those three in
order; `recolorIconText(text, accent)`; and `hyprlandBorderCommands(his,
accent, dark)`, which returns an argv array invoking
`hyprctl eval 'hl.config({...})'`, or null when there is no instance
signature. It is not a border string.
- [ ] **1** Write `tst_tint.qml` from the fixtures already in
      `rust/wallpaper-tui/tests/tint.rs`, one `_data()` row per fixture
- [ ] **2** Run QtTest Expected: FAIL
- [ ] **3** Port the writers. Kvantum matches the 7-char body only
- [ ] **4** Run QtTest Expected: PASS
- [ ] **5** Add the alpha-preservation case: `#8caaeeff` keeps its `ff`
- [ ] **6** Run QtTest Expected: PASS
- [ ] **7** `git commit -m "port the tint writers to the shell"`

### Task 3: Prove the two agree with the crate
**Files:** create `tests/qml/tst_tint_parity.qml`.
**Produces** nothing new; it lets plan 1b delete the crate without losing
the parity evidence.
- [ ] **1** With Task 1's `--dump-accent`, record the crate's accent triple
      and its `hyprlandBorderCommands` argv for three 64x64 lossless PNGs
      of differing dominant hue, then revert the patch. 64x64 because
      that is the only size where both scalers agree exactly (Task 1)
- [ ] **2** Write `tst_tint_parity.qml` asserting `accentFrom` +
      `hyprlandBorderCommands` reproduce all three, exactly
- [ ] **3** Run QtTest Expected: PASS
- [ ] **4** `nix run .#nix-lint` Expected: green
- [ ] **5** `git commit -m "pin the ported tint maths to the crate's output"`
