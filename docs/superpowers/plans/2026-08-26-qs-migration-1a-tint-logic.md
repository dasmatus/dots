# Quickshell Migration 1a: Tint Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Port `accent.rs` and `tint.rs`'s pure functions to JS under
QtTest, before any wallpaper pixel is drawn by the shell.
**Architecture:** Two JS modules with no QML surface, so every one of them
is testable offscreen. `wallpaper-tui` still runs and still owns the
wallpaper; this plan only proves the replacement maths. Quickshell 0.3,
Qt 6.11, QtTest. Needs plan 0's `common/hls.js`.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
From `accent.rs`/`tint.rs`; reproduce exactly or the ported vectors break.
- 64x64 downsample, 16 hue bins, drop near-black/near-white/low-sat, win =
  largest saturation-weighted bin. Accent L=0.62 S=0.55; dark L=0.40,
  light L=0.78.
- `ADWAITA_BLUE_HEXES` = #1c71d8 #438de6 #3584e4 #62a0ea #99c1f1 #afd4ff
- `KVANTUM_ACCENT_HEXES` = #8caaee #839edd #98b2ef, case-insensitive,
  7-char body only so trailing alpha survives.
- `drawImage` needs the URL string after `loadImage()`; an `Image` item
  draws transparent black and reports no error. This cost an afternoon
  during the spike; do not "simplify" it back.

---

### Task 1: The accent extractor
**Files:** create `qml/wallpaper/accent.js`, `tests/qml/tst_accent.qml`.
**Consumes** `common/hls.js`. **Produces** `accentFrom(pixels)`, taking an RGBA
`Uint8ClampedArray` in, `{accent, dark, light}` as `#rrggbb` out.

- [ ] **1** Record the oracle first: run
      `wallpaper-tui --output '*' Wallpapers/wh/wallhaven-7jeozo.jpg`
      and save the accent from `tint/current.json`. This is the value
      Task 1 must reproduce, and the crate is deleted in plan 1b
- [ ] **2** Write `tst_accent.qml`: `Canvas` with
      `renderTarget: Canvas.Image`, `loadImage` in `Component.onCompleted`,
      `drawImage`+`getImageData` in `onPaint`, asserting the Step 1 value
- [ ] **3** Run QtTest Expected: FAIL, `accentFrom` undefined
- [ ] **4** Port the bucket loop from `accent.rs` into `accent.js`
- [ ] **5** Run QtTest Expected: PASS
- [ ] **6** Add a second case: an all-black PNG falls back rather than
      returning `#000000`, matching `DEFAULT_ACCENT`
- [ ] **7** Run QtTest Expected: PASS
- [ ] **8** `git commit -m "read the wallpaper accent from a canvas"`

### Task 2: The tint writers
**Files:** create `qml/wallpaper/tint.js`, `tests/qml/tst_tint.qml`.
**Produces** `hyprBorder(a)`, `rofi(t,a)`, `gtk(t,a)`, `kvantum(t,a)` and
`recolorIconText(t,a)`, all pure string->string, mirroring `tint.rs`.

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
**Produces** nothing new; this task exists so plan 1b can delete the crate
without the parity evidence disappearing with it.

- [ ] **1** For three wallpapers of different dominant hue, record the
      crate's accent and its rendered Hyprland border string
- [ ] **2** Write `tst_tint_parity.qml` asserting `accentFrom` +
      `hyprBorder` reproduce all three
- [ ] **3** Run QtTest Expected: PASS
- [ ] **4** `nix run .#nix-lint` Expected: green
- [ ] **5** `git commit -m "pin the ported tint maths to the crate's output"`
