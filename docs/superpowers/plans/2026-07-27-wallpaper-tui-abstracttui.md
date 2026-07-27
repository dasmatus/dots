# wallpaper-tui → abstracttui Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `wallpaper-tui`'s TUI layer from `ratatui`+`crossterm`+`ratatui-image` onto `abstracttui 0.2.x`, render the preview through the mosaic/emulator backend (no native image-protocol negotiation), add a preview crossfade + selection-slide animation, and keep all non-TUI tests green.

**Architecture:** Same Approach A as the installer — keep `App` (`app.rs`) as the pure state machine, hold it in `Signal<App>`, project via `dyn_view`. The `ratatui_image::Picker`/`StatefulProtocol` fields are removed; the preview becomes a `gfx::Bitmap` derived from the cached `image::DynamicImage` and shown through the `Image` widget on the mosaic backend. A `fx.rs` overlay adds the crossfade, gated by `DOTS_NO_ANIM`.

**Tech Stack:** Rust 2021, `abstracttui = "0.2"`, existing non-TUI modules (`config`, `awww`, `accent`, `tint`, `preview`, `wallpapers`, `cli`), `image` (kept), `mpsc` + `std::thread` worker pattern (unchanged).

## Global Constraints

- Non-TUI modules (`cli.rs`, `config.rs`, `awww.rs`, `accent.rs`, `tint.rs`, `preview.rs`, `wallpapers.rs`) are **untouched** — no logic, no signature changes. `preview::load_preview` must keep returning `image::DynamicImage` so `tests/preview.rs` stays green.
- `App::handle_key` stays a pure transition function; only its parameter type changes to `crate::input::KeyEvent`. There is no `app` state-machine test, so no test edits required for the shim.
- The `Image` widget runs on the **mosaic/emulator backend** (half-block/quadrant/sextant/braille cell glyphs) — **no** native kitty/iTerm2/sixel negotiation. `MosaicMode` chosen via `use_caps` (half-blocks on raw VTs).
- No inline tests — new tests in `tests/`.
- Comments: top-level (`//!`) / per-symbol (`///`) only.
- No `Co-Authored-By`/session-link in commits.
- The authoritative abstracttui signature reference is `docs/superpowers/refs/abstracttui-api.md` (created by the installer-tui plan's Task 0). This plan's Task 0 **extends** that reference with the `Image`-mosaic + `Bitmap`-from-`DynamicImage` specifics. When code disagrees with the reference, the reference wins — adjust until `cargo check` passes.
- `cargo fmt --all` and `cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic` clean before each commit.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `rust/wallpaper-tui/Cargo.toml` | Drop `ratatui`+`crossterm`+`ratatui-image`, add `abstracttui = "0.2"`; keep `image` | 0,1 |
| `rust/wallpaper-tui/examples/spike.rs` | Throwaway probe exercising the Image-mosaic + Bitmap-from-DynamicImage path headless | 0 |
| `docs/superpowers/refs/abstracttui-api.md` | Extended with §Image-mosaic + §Bitmap-from-DynamicImage | 0 |
| `rust/wallpaper-tui/src/input.rs` | **New.** Engine-agnostic `KeyCode`/`KeyEvent` shim (identical to installer's) | 1 |
| `rust/wallpaper-tui/src/app.rs` | `handle_key` param type; drop `Picker`/`StatefulProtocol` fields; preview → `Bitmap`; logic preserved | 1 |
| `rust/wallpaper-tui/src/fx.rs` | **New.** Preview crossfade + selection slide, `DOTS_NO_ANIM`-gated | 2 |
| `rust/wallpaper-tui/src/ui.rs` | **Full rewrite.** `List` + `Image`(mosaic) + info/help bars | 3,4 |
| `rust/wallpaper-tui/src/main.rs` | **Rewrite.** abstracttui runtime + custom loop + apply/preview worker bridge | 5 |
| `rust/wallpaper-tui/src/lib.rs` | Re-export `input`, `fx` | 1,2 |
| `rust/wallpaper-tui/tests/view.rs` | **New.** Headless render + crossfade tests | 3,4,6 |

---

### Task 0: Image-mosaic API spike (extends the shared reference)

**Goal:** Build a throwaway example that loads a PNG via the existing `preview::load_preview`, converts the `image::DynamicImage` to `abstracttui::gfx::Bitmap`, and displays it headless through the `Image` widget on the mosaic backend — confirming the `Image`/`ImageFit`/`ImageAlign`/`MosaicMode` APIs and the `DynamicImage→Bitmap` conversion. Extend `docs/superpowers/refs/abstracttui-api.md` with the findings.

**Files:**
- Create: `rust/wallpaper-tui/examples/spike.rs`
- Modify: `rust/wallpaper-tui/Cargo.toml` (add `abstracttui = "0.2"`; keep `ratatui`/`crossterm`/`ratatui-image` for now — removed in Task 1)
- Modify: `docs/superpowers/refs/abstracttui-api.md` (append §Image-mosaic, §Bitmap-from-DynamicImage)

**Interfaces:**
- Consumes: `preview::load_preview`; the existing `docs/superpowers/refs/abstracttui-api.md` core sections.
- Produces: confirmed `Image`/`ImageFit`/`ImageAlign`/`MosaicMode` signatures + the `DynamicImage→Bitmap` recipe in the reference.

- [ ] **Step 1: Add abstracttui + the example to Cargo.toml**

```toml
[dependencies]
abstracttui = "0.2"
ratatui = "0.29"          # removed in Task 1
crossterm = "0.28"        # removed in Task 1
ratatui-image = { version = "=8.1.1", default-features = false, features = ["crossterm"] } # removed in Task 1
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
image = "0.25"
regex = "1"
sha1 = "0.10"
clap = { version = "4", features = ["derive"] }
walkdir = "2"

[[example]]
name = "spike"
```

- [ ] **Step 2: Write the spike**

`rust/wallpaper-tui/examples/spike.rs`:

```rust
//! Throwaway abstracttui Image-mosaic probe. Delete after the migration lands.
use abstracttui::prelude::*;
use abstracttui::gfx::Bitmap;
use abstracttui::base::Rgba;

fn main() -> anyhow::Result<()> {
    // 1. Build a 4x4 RGBA test image as a Bitmap (no I/O needed for the probe):
    let px: Vec<Rgba> = (0..16).map(|i| Rgba::new(i as u8, 255 - i as u8, 0, 255)).collect();
    let bmp = Bitmap::from_pixels(4, 4, px).expect("16 px");
    // 2. Mount an App whose root is an Image widget showing `bmp` on the mosaic
    //    backend with ImageFit::Contain, ImageAlign::Center. Confirm the real
    //    Image constructor + how to force mosaic mode (not native protocol).
    // 3. Render one frame to a CaptureTerm and assert_snapshot.
    // 4. Separately, confirm the DynamicImage -> Bitmap recipe:
    //    let dyn_img = image::DynamicImage::new_rgba8(2,2);
    //    let rgba = dyn_img.to_rgba8();
    //    let vec: Vec<Rgba> = rgba.pixels().map(|p| Rgba::new(p.0[0],p.0[1],p.0[2],p.0[3])).collect();
    //    let _bmp = Bitmap::from_pixels(rgba.width(), rgba.height(), vec);
    Ok(())
}
```

Iterate against `cargo run --example spike` and the docs.rs **source-view** pages (`https://docs.rs/abstracttui/0.2.24/src/abstracttui/widgets/image.rs.html` or wherever `Image` lives; `https://docs.rs/abstracttui/0.2.24/src/abstracttui/gfx/mosaic.rs.html` for `MosaicMode`) until it compiles and renders headless. Confirm: the `Image` constructor's exact args, how to bind a `Bitmap` (owned? signal? `&`?), how to select `ImageFit`/`ImageAlign`, and how to force the mosaic renderer (skip `choose_channel`'s kitty/iterm2/sixel rungs).

- [ ] **Step 3: Extend the shared reference doc**

Append to `docs/superpowers/refs/abstracttui-api.md`:
- **§Image widget:** `Image::new` exact signature; how the `Bitmap` is supplied; `ImageFit` variants; `ImageAlign` variants; how to force the mosaic/emulator backend (the call/site that bypasses native protocols).
- **§MosaicMode:** the enum variants (half-block/quadrant/sextant/braille) and how `use_caps` selects one for raw-VT safety.
- **§Bitmap-from-DynamicImage:** the verified recipe (`to_rgba8()` → `Vec<Rgba>` via the confirmed `Rgba` constructor → `Bitmap::from_pixels(w, h, vec)`), including the `image::Rgba<u8>` → `abstracttui::base::Rgba` element mapping.

- [ ] **Step 4: Verify**

Run: `cd rust/wallpaper-tui && cargo check --example spike`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/wallpaper-tui
git add Cargo.toml examples/spike.rs ../../docs/superpowers/refs/abstracttui-api.md
git commit -m "feat(wallpaper-tui): abstracttui Image-mosaic spike + reference"
```

---

### Task 1: Dependency swap + `input` shim + `app.rs` field surgery

**Goal:** Remove `ratatui`/`crossterm`/`ratatui-image`, add the `input` shim, switch `handle_key` to it, and remove the `Picker`/`StatefulProtocol` fields from `App` — replacing the on-screen preview with a `gfx::Bitmap`. `App::new` drops its `picker` parameter. Non-TUI tests stay green; the TUI builds only after Tasks 3-5.

**Files:**
- Modify: `rust/wallpaper-tui/Cargo.toml`
- Create: `rust/wallpaper-tui/src/input.rs`
- Modify: `rust/wallpaper-tui/src/app.rs`
- Modify: `rust/wallpaper-tui/src/lib.rs`
- (No test edits — there is no `app` state-machine test.)

**Interfaces:**
- Consumes: `abstracttui::gfx::Bitmap`; the `Bitmap-from-DynamicImage` recipe from the reference.
- Produces: `pub mod input;` with `KeyCode`/`KeyEvent`; `App` without `picker`/`preview: StatefulProtocol`, with `preview: Option<Bitmap>`; `App::new(config, state, no_tint, backend) -> Self` (no `picker`).

- [ ] **Step 1: Write the `input` shim**

`rust/wallpaper-tui/src/input.rs` — identical to the installer's `input.rs` (`KeyCode::{Char,Enter,Esc,Backspace,Up,Down}`, `KeyEvent{code}`, `From<KeyCode>`). The keys the wallpaper TUI uses: `q`/Esc, `j`/Down, `k`/Up, Enter, `m`, `c`, `o`, `p`, `r` — all covered by `Char` + the named variants.

- [ ] **Step 2: Swap `app.rs` key type + remove image-protocol fields**

In `rust/wallpaper-tui/src/app.rs`:
- Remove `use ratatui_image::picker::Picker;` and `use ratatui_image::protocol::StatefulProtocol;` (lines 9-10).
- Add `use crate::input::{KeyCode, KeyEvent};` and `use abstracttui::gfx::Bitmap;`.
- In `App`, **remove** `pub picker: Picker,` and `pub preview: Option<StatefulProtocol>,`.
- **Add** `pub preview: Option<Bitmap>,` (the on-screen bitmap, derived from the cache).
- Keep `pub preview_cache: HashMap<String, image::DynamicImage>,` unchanged.
- Change `handle_key(&mut self, key: crossterm::event::KeyEvent)` → `handle_key(&mut self, key: KeyEvent)`; replace the inner `use crossterm::event::KeyCode;` with the imported `KeyCode`. Logic unchanged.
- `App::new(config, state, no_tint, backend)` — drop the `picker` parameter; remove the `picker` field init; init `preview: None`. The body otherwise unchanged (outputs/fill_mode/current_color logic identical).
- `request_preview`: replace `self.picker.new_resize_protocol(img)` with a `DynamicImage→Bitmap` conversion helper `fn dynimg_to_bitmap(img: &image::DynamicImage) -> Bitmap` (the reference recipe). On cache hit, set `self.preview = Some(dynimg_to_bitmap(&img))`. On miss, keep the `PendingOp::Preview { path }` dispatch unchanged.
- `on_event`'s `PreviewReady` arm: replace `self.picker.new_resize_protocol(img.clone())` with `let bmp = dynimg_to_bitmap(&img); self.preview = Some(bmp);` then `self.preview_cache.insert(path, img);`. The `None` branch keeps `self.preview = None`.
- Add `#[derive(Clone)]` to `App` if not present (needed to put it in a `Signal`); verify all fields are `Clone` (`Bitmap` is `Clone`, `HashMap<String, DynamicImage>` is `Clone`, `Config`/`State`/`TintBackend` are `Clone`).

- [ ] **Step 3: Export `input` + the bitmap helper**

`rust/wallpaper-tui/src/lib.rs` — add `pub mod input;`. Keep `pub fn` re-exports as-is. The `dynimg_to_bitmap` helper can live private in `app.rs` (used only there) or in a new `pub mod gfx_util;` if `ui.rs` also needs it — default to private in `app.rs` unless `ui.rs` needs it.

- [ ] **Step 4: Swap Cargo.toml deps**

```toml
[dependencies]
abstracttui = "0.2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
image = "0.25"
regex = "1"
sha1 = "0.10"
clap = { version = "4", features = ["derive"] }
walkdir = "2"
```

(Drop `ratatui`, `crossterm`, `ratatui-image`.)

- [ ] **Step 5: Verify non-TUI tests still pass; TUI expected red**

Run: `cd rust/wallpaper-tui && cargo test --test preview && cargo test --test accent && cargo test --test awww && cargo test --test tint && cargo test --test config`
Expected: PASS (these don't touch `app.rs`).
Run: `cd rust/wallpaper-tui && cargo check`
Expected: FAIL only in `ui.rs` and `main.rs` (still reference removed deps / old `App::new` signature). Expected — rewritten in Tasks 3-5.

- [ ] **Step 6: Commit**

```bash
cd rust/wallpaper-tui
git add Cargo.toml src/input.rs src/app.rs src/lib.rs
git commit -m "refactor(wallpaper-tui): engine-agnostic input shim, drop ratatui-image for Bitmap preview"
```

---

### Task 2: `fx` overlay — preview crossfade + selection slide

**Goal:** Create `src/fx.rs` with a preview crossfade (`Transition` on opacity between successive `Bitmap`s) and a list selection slide, gated by `DOTS_NO_ANIM`. Unit-test the crossfade math with `Clock::fixed`.

**Files:**
- Create: `rust/wallpaper-tui/src/fx.rs`
- Modify: `rust/wallpaper-tui/src/lib.rs`
- Test: `rust/wallpaper-tui/tests/fx.rs`

**Interfaces:**
- Consumes: `abstracttui::anim` (`Clock`, `Transition`, `Easing`, `FrameRequester`) from the reference.
- Produces: `pub fn animations_enabled() -> bool`; `pub struct Fx` with `crossfade_opacity(&self) -> f32`, `selection_offset(&self) -> f32`, `retarget_crossfade(&self)`, `retarget_selection(&self, to: f32)`.

- [ ] **Step 1: Write the failing test**

`rust/wallpaper-tui/tests/fx.rs`:

```rust
use wallpaper_tui::fx::crossfade_curve;

#[test]
fn crossfade_rises_to_one_then_settles() {
    let curve = crossfade_curve(150);
    assert!((curve.now(0)).abs() < 1e-6);     // starts invisible
    assert!((curve.now(150) - 1.0).abs() < 1e-6); // fully visible at duration
    assert!(curve.now(75) > 0.0 && curve.now(75) < 1.0); // mid-fade
}

#[test]
fn animations_enabled_respects_env() {
    std::env::set_var("DOTS_NO_ANIM", "1");
    assert!(!wallpaper_tui::fx::animations_enabled());
    std::env::remove_var("DOTS_NO_ANIM");
    assert!(wallpaper_tui::fx::animations_enabled());
}
```

(Adjust `now(ms)` / `crossfade_curve` to the confirmed `Clock`/`Tween` API; the property — 0→1 over the duration — is the contract.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust/wallpaper-tui && cargo test --test fx`
Expected: FAIL.

- [ ] **Step 3: Implement `fx.rs`**

```rust
//! Animation overlay for the wallpaper TUI: preview crossfade + selection slide.
//! Gated by DOTS_NO_ANIM; collapses to instant cuts when disabled.
use abstracttui::anim::{Clock, Easing, FrameRequester, Transition};

pub fn animations_enabled() -> bool { std::env::var("DOTS_NO_ANIM").is_err() }

pub struct Fx {
    crossfade: Transition<f32>,   // 0 (old) -> 1 (new)
    selection: Transition<f32>,   // eased list highlight offset
    requester: FrameRequester,
}

impl Fx {
    pub fn new(clock: Clock) -> Self { todo_build_from_reference() }
    pub fn retarget_crossfade(&self) { self.crossfade.set_target(1.0, ms(150)); self.request(); }
    pub fn retarget_selection(&self, to: f32) { self.selection.set_target(to, ms(90)); self.request(); }
    pub fn crossfade_opacity(&self) -> f32 { self.crossfade.value() }
    pub fn selection_offset(&self) -> f32 { self.selection.value() }
    fn request(&self) { if animations_enabled() { self.requester.request(); } }
}
```

Plus the `crossfade_curve` test helper wrapping a `Tween::new(0.0, 1.0, ms(150))` with `Easing::EaseOut`. Resolve `todo_*` / `Transition::set_target`/`value`/`ms`/`FrameRequester::request` against the reference.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust/wallpaper-tui && cargo test --test fx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/wallpaper-tui
git add src/fx.rs src/lib.rs tests/fx.rs
git commit -m "feat(wallpaper-tui): fx overlay (preview crossfade + selection slide, DOTS_NO_ANIM-gated)"
```

---

### Task 3: `ui.rs` — list + info/help bars

**Goal:** Rewrite `ui.rs` as an abstracttui View: a horizontal `List` (wallpapers) | preview pane, above an info bar, above a one-line help footer — flexbox layout. The preview pane is a placeholder in this task (drawn in Task 4). Verify the list/info/help render headless.

**Files:**
- Modify: `rust/wallpaper-tui/src/ui.rs` (full rewrite)
- Test: `rust/wallpaper-tui/tests/view.rs` (new)

**Interfaces:**
- Consumes: `App` from `crate::app`; `List`/`RichTextView`/`Style` APIs from the reference; the `HELP` const string from the old `ui.rs`.
- Produces: `pub fn root_view(cx: Scope, app: Signal<App>, fx: Signal<Fx>) -> View`; `pub fn info_text(app: &App) -> String` (port of `App::info_text`, or call it directly).

- [ ] **Step 1: Write the failing render tests**

`rust/wallpaper-tui/tests/view.rs`:

```rust
use wallpaper_tui::app::App;
use wallpaper_tui::ui;

fn render_to_string(app: &App, cols: u16, rows: u16) -> String {
    // CaptureTerm of cols×rows, mount ui::root_view over Signal<App>=app.clone(),
    // pump one frame, return rendered text. Harness per the reference §Testing.
    todo_harness_from_reference()
}

#[test]
fn empty_state_lists_no_wallpapers_message() {
    let app = App::new(/* config */ todo_cfg(), /* state */ todo_state(), false, /* backend */ todo_backend());
    // wallpapers empty → "No wallpapers found in: <folder>"
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("No wallpapers found"));
}

#[test]
fn list_shows_wallpaper_names_and_help_line() {
    let app = App::new(todo_cfg_with_folder(), todo_state(), false, todo_backend());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("Enter:apply"));
    assert!(out.contains("wallpapers")); // list block title
}
```

Build the `todo_cfg/state/backend` fixtures from `wallpaper_tui::config::{Config, State}` and `wallpaper_tui::accent::TintBackend` exactly as the existing `tests/config.rs`/`tests/accent.rs` do — reuse their construction patterns. Implement `todo_harness_from_reference()` per the reference §Testing (`CaptureTerm` + `driver.turn`/`app.pump` + `assert_snapshot`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd rust/wallpaper-tui && cargo test --test view`
Expected: FAIL.

- [ ] **Step 3: Implement `root_view` + list + info + help**

`rust/wallpaper-tui/src/ui.rs`:

```rust
//! abstracttui view: list | preview above info above help. Pure projection of &App.
use abstracttui::prelude::*;
use crate::app::App;
use crate::fx::Fx;

const HELP: &str = "Enter:apply  j/k:move  m:mode  c:color  o:output  p:preview  r:restore  q:quit";

pub fn root_view(cx: Scope, app: Signal<App>, fx: Signal<Fx>) -> View {
    Element::new()
        .style(Style::column())
        .child(dyn_view(Style::default(), move || {
            let a = app.get();
            if a.wallpapers.is_empty() {
                empty_view(&a)
            } else {
                main_view(&a)
            }
        }))
        .build()
}
```

`main_view`: a column whose first row is a horizontal split (`Style::row()`) — `List` (left, grow) | preview placeholder (`Block` with left border, fixed width ~50) — second row is the info bar (`RichTextView` styled like the old `draw_info`: dark-gray bg, white bold), third row is the help line (dim `RichTextView`). `empty_view`: a `RichTextView` with "No wallpapers found in: {folder}" + the info + help rows. The `List` items are wallpaper file names; highlight the `app.selected` index with the old highlight style (black on light-blue, bold, `> ` symbol). Copy the `HELP` string and info-bar format verbatim from the old `ui.rs`/`app.rs::info_text`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust/wallpaper-tui && cargo test --test view`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/wallpaper-tui
git add src/ui.rs tests/view.rs
git commit -m "feat(wallpaper-tui): abstracttui list + info/help layout"
```

---

### Task 4: `ui.rs` — `Image` preview on the mosaic backend

**Goal:** Replace the preview placeholder with the `Image` widget rendering `app.preview: Option<Bitmap>` through the mosaic/emulator backend, with the crossfade applied (Task 2's `fx.crossfade_opacity()`). Handle the "rendering…"/"[preview unavailable]" fallback labels.

**Files:**
- Modify: `rust/wallpaper-tui/src/ui.rs`
- Test: `rust/wallpaper-tui/tests/view.rs`

**Interfaces:**
- Consumes: `Image`/`ImageFit`/`ImageAlign`/`MosaicMode` from the reference (Task 0's spike); `app.preview`, `app.preview_pending`, `app.show_preview`; `Fx`.
- Produces: `fn preview_view(&App, &Fx) -> View`.

- [ ] **Step 1: Write failing render tests**

```rust
#[test]
fn preview_pane_shows_unavailable_label_when_no_bitmap() {
    let app = App::new(todo_cfg_with_folder(), todo_state(), false, todo_backend());
    // no preview decoded yet and nothing pending
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("[preview unavailable]") || out.contains("rendering"));
}

#[test]
fn preview_pane_shows_image_when_bitmap_present() {
    let mut app = App::new(todo_cfg_with_folder(), todo_state(), false, todo_backend());
    app.preview = Some(small_test_bitmap()); // 4x4 RGBA via Bitmap::from_pixels
    let out = render_to_string(&app, 80, 24);
    // The mosaic renderer writes glyph cells into the preview region; assert the
    // region is non-empty / the unavailable label is gone. Use assert_snapshot
    // for an exact golden if a text-cell check is too brittle.
    assert!(!out.contains("[preview unavailable]"));
}

fn small_test_bitmap() -> abstracttui::gfx::Bitmap {
    use abstracttui::base::Rgba;
    let px: Vec<Rgba> = (0..16).map(|i| Rgba::new(i as u8, 0, 0, 255)).collect();
    abstracttui::gfx::Bitmap::from_pixels(4, 4, px).expect("16 px")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd rust/wallpaper-tui && cargo test --test view`
Expected: FAIL.

- [ ] **Step 3: Implement `preview_view`**

In `main_view`, the preview pane becomes:
- If `!app.show_preview`: a `Block` with a left border (mirrors old behavior).
- Else if `let Some(bmp) = &app.preview`: an `Image` widget showing `bmp` via the mosaic backend, `ImageFit::Contain`, `ImageAlign::Center`. Apply the crossfade: when `animations_enabled()`, blend the new bitmap's opacity by `fx.crossfade_opacity()` (if the `Image` widget / paint style exposes an alpha knob — confirm in the reference; else drive the crossfade by drawing the old bitmap at `1 - opacity` and the new at `opacity` if the engine supports two overlapping images, else fall back to an instant cut and document that crossfade is best-effort). `MosaicMode` selected via `use_caps` — half-blocks on raw VTs, richer glyphs on full terminals.
- Else (no bitmap, decode pending or failed): a `RichTextView` with `"rendering…"` if `app.preview_pending.is_some()` else `"[preview unavailable]"`.

Wire the crossfade retarget: in `root_view`'s `dyn_view`, keep a `Signal<Option<String>>` (`last_preview_path`); when `app.selected_path()` changes, call `fx.get().retarget_crossfade()` and update the signal.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust/wallpaper-tui && cargo test --test view`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/wallpaper-tui
git add src/ui.rs tests/view.rs
git commit -m "feat(wallpaper-tui): mosaic-backed Image preview with crossfade"
```

---

### Task 5: `main.rs` — runtime + custom loop + worker bridge

**Goal:** Replace the ratatui/crossterm event loop with an abstracttui runtime: build `App` (no `Picker`), wrap in `Signal<App>`, mount `root_view`, run a custom loop draining `apply_rx`/`preview_rx` into `on_event`, dispatching `pending` (Apply/Restore/Preview) to worker threads, feeding key events into `handle_key`, quitting via `quitter` when `should_quit`. Drop `Picker::from_query_stdio` entirely. Non-interactive CLI paths (`--restore`, `--cache-previews`, `--path`) stay unchanged.

**Files:**
- Modify: `rust/wallpaper-tui/src/main.rs` (full rewrite)

**Interfaces:**
- Consumes: `App::new` (new 4-arg signature); `ui::root_view`; `fx::Fx`; `apply_wallpaper`/`LiveAwww`/`tint::apply_tint`/`preview::load_preview` (unchanged); the custom-loop + key-bridge recipe from the reference (same as the installer's Task 7).
- Produces: a working `main.rs` running the wallpaper TUI on abstracttui.

- [ ] **Step 1: Rewrite `main.rs`**

Keep `resolve_backend`, `main()`'s non-interactive dispatch (`args.restore`, `args.cache_previews`, `args.path`) **byte-for-byte** — only `run_tui` is rewritten. The new `run_tui`:

```rust
fn run_tui(config: Config, state: State, no_tint: bool, backend: TintBackend) -> anyhow::Result<()> {
    let mut app_state = App::new(config, state, no_tint, backend); // no picker
    app_state.request_preview();

    let (apply_tx, apply_rx) = std::sync::mpsc::channel::<Event>();
    let (preview_tx, preview_rx) = std::sync::mpsc::channel::<Event>();

    let mut engine = App::new(viewport_80x24_or_detected());       // reference: Size
    let cx = todo_root_scope();
    let app_sig = cx.signal(app_state.clone());
    let fx_sig = cx.signal(Fx::new(todo_clock()));
    engine.mount(ui::root_view(cx, app_sig, fx_sig))?;

    while !engine.quit_requested() {
        while let Ok(ev) = apply_rx.try_recv() { app_state.on_event(ev); }
        while let Ok(ev) = preview_rx.try_recv() { app_state.on_event(ev); }
        if let Some(op) = app_state.pending.take() {
            match op {
                PendingOp::Apply { group, transition_type, transition_duration, no_tint, backend } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        let groups = vec![group.clone()];
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let status = tint::apply_tint(&group.path, no_tint, backend);
                        let msg = match status { Some(s) => format!("applied {} (tint {})", group.path, s.qt), None => format!("applied {}", group.path) };
                        let _ = tx.send(Event::ApplyDone { msg });
                    });
                }
                PendingOp::Restore { groups, transition_type, transition_duration, no_tint, backend } => {
                    let tx = apply_tx.clone();
                    std::thread::spawn(move || {
                        apply_wallpaper(&LiveAwww, &groups, &transition_type, transition_duration);
                        let tint_path = groups.first().map_or("", |g| g.path.as_str());
                        let status = if tint_path.is_empty() { None } else { tint::apply_tint(tint_path, no_tint, backend) };
                        let msg = match status { Some(s) => format!("restored {} (tint {})", groups.len(), s.qt), None => format!("restored {} output(s)", groups.len()) };
                        let _ = tx.send(Event::ApplyDone { msg });
                    });
                }
                PendingOp::Preview { path } => {
                    let tx = preview_tx.clone();
                    std::thread::spawn(move || {
                        let image = preview::load_preview(&path).ok();
                        let _ = tx.send(Event::PreviewReady { path, image });
                    });
                }
            }
        }
        app_sig.set(app_state.clone());
        todo_pump_one_step(&mut engine); // reference: pump/turn with short timeout
        app_state = app_sig.get();
    }
    Ok(())
}
```

The key bridge lives in `root_view`'s root `on_event` (identical pattern to the installer's Task 7): map `UiEvent::Key(k.key)` → `input::KeyCode` (`Char('q')`/`Esc`→quit, `Char('j')`/`Down`→Down, `Char('k')`/`Up`→Up, `Enter`, `Char('m')`,`Char('c')`,`Char('o')`,`Char('p')`,`Char('r')`), call `app.handle_key(...)`, `set` the signal, quit when `should_quit`. Resolve every `todo_*` against the reference.

- [ ] **Step 2: Verify it compiles**

Run: `cd rust/wallpaper-tui && cargo check`
Expected: PASS (first full green since Task 1).

- [ ] **Step 3: Manual smoke test**

Run: `cd rust/wallpaper-tui && cargo run`
Expected: the wallpaper list renders with a mosaic preview of the current selection; `j`/`k` moves the selection (preview crossfades); `Enter` applies (info bar updates); `p` toggles preview; `q` exits cleanly with the terminal restored.

- [ ] **Step 4: Full suite + fmt + clippy**

Run: `cd rust/wallpaper-tui && cargo test && cargo fmt --all && cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic`
Expected: all PASS / clean.

- [ ] **Step 5: Commit**

```bash
cd rust/wallpaper-tui
git add src/main.rs
git commit -m "feat(wallpaper-tui): abstracttui runtime + custom loop + apply/preview worker bridge"
```

---

### Task 6: Full headless render + crossfade test suite

**Goal:** Harden `tests/view.rs` into a complete suite: list render, empty state, info bar text, help line, preview unavailable label, preview-with-bitmap, and the crossfade property test.

**Files:**
- Modify: `rust/wallpaper-tui/tests/view.rs`

**Interfaces:**
- Consumes: everything above.
- Produces: a green, comprehensive `tests/view.rs`.

- [ ] **Step 1: Consolidate the suite**

Ensure `tests/view.rs` covers: empty-state message, list+help+info render, preview-unavailable label, preview-with-bitmap (snapshot), and a crossfade test (`Clock::fixed`; select path A → pump → select path B → pump; assert `fx.crossfade_opacity()` rose from 0 toward 1 across frames). Use `assert_snapshot` (with `UPDATE_GOLDELS=1` to seed) for the list and preview-with-bitmap cases.

- [ ] **Step 2: Run the full suite**

Run: `cd rust/wallpaper-tui && cargo test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd rust/wallpaper-tui
git add tests/view.rs
git commit -m "test(wallpaper-tui): full headless render + crossfade suite"
```

---

## Notes for the executor

- This plan **extends** `docs/superpowers/refs/abstracttui-api.md` (created by the installer-tui plan's Task 0). If the installer plan hasn't run yet, this plan's Task 0 creates the reference's core sections too — coordinate so the two plans don't clobber the file (append, don't overwrite).
- `preview::load_preview` stays returning `image::DynamicImage` — the conversion to `Bitmap` happens in `app.rs`. `tests/preview.rs` is untouched.
- The mosaic backend is mandatory (no native image protocols) — do not call `choose_channel`'s kitty/iterm2/sixel rungs. The spike (Task 0) confirms how to force mosaic.
- `cargo check` after Task 1 will be red in `ui.rs`/`main.rs` until Tasks 3-5 land — expected. Commit Task 1 after the non-TUI tests pass.
- Preserve the `HELP` string and info-bar format verbatim from the old `ui.rs`/`app.rs`.
- Keep `examples/spike.rs` until the migration is fully green; remove in a final cleanup commit if desired.