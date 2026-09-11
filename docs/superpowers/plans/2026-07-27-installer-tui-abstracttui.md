# installer-tui → abstracttui migration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `installer-tui`'s entire TUI layer (event loop, view, key-event type) from `ratatui`+`crossterm` onto `abstracttui 0.2.x`, add tasteful animations, and keep the existing pure state machine + its test suite green.

**Architecture:** Approach A from the design spec. Keep `App` (`app.rs`) as the pure, testable state machine; hold it in one `abstracttui` `Signal<App>`; build the View tree in a `dyn_view` reactive region that projects `App` onto abstracttui widgets; route engine key events into `App::handle_key`; drain worker `mpsc` channels each custom-loop iteration. A small `fx.rs` overlay adds `anim`-driven transitions, gated by `DOTS_NO_ANIM`.

**Tech Stack:** Rust 2021, `abstracttui = "0.2"`, existing non-TUI modules (`config`, `disks`, `net`, `install`), `mpsc` + `std::thread` worker pattern (unchanged).

## Global Constraints

- Non-TUI modules (`config.rs`, `disks.rs`, `net.rs`, `install.rs`) are **untouched**. No logic, no signature changes. Their tests must stay green.
- `App`'s public fields and `Screen` enum stay public and structurally identical. `tests/app.rs` sets fields directly (`app.screen = …`, `app.wifi_networks = …`).
- `App::handle_key` stays a pure transition function; only its parameter type changes (`crossterm::event::KeyEvent` → `crate::input::KeyEvent`). All test call sites (`key(KeyCode::Char(c))`, `KeyEvent::from(code)`) keep working.
- No inline tests. New tests go in `tests/` per the repo rule.
- Comments: top-level (`//!`) and per-symbol (`///`) only; inline `//` only for "magic sorcery".
- No `Co-Authored-By`/session-link in commits (per project CLAUDE.md).
- `abstracttui 0.2.x` is brand-new (published 2026-07-26); exact widget signatures are confirmed empirically by the Task 0 spike and recorded in `docs/superpowers/refs/abstracttui-api.md`. When a task's code block disagrees with that reference, **the reference wins**. Adjust the code so `cargo check` passes.
- Formatting: `cargo fmt --all`; lints: `cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic` must be clean before each commit.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `rust/installer-tui/Cargo.toml` | Dep swap: drop `ratatui`+`crossterm`, add `abstracttui = "0.2"` | 0,1 |
| `rust/installer-tui/examples/spike.rs` | Throwaway compiling probe exercising every abstracttui API the migration uses | 0 |
| `docs/superpowers/refs/abstracttui-api.md` | Authoritative confirmed-signature reference, produced by the spike | 0 |
| `rust/installer-tui/src/input.rs` | **New.** Engine-agnostic `KeyCode`/`KeyEvent` shim | 1 |
| `rust/installer-tui/src/app.rs` | `handle_key` param type → `input::KeyEvent`; logic unchanged | 1 |
| `rust/installer-tui/src/fx.rs` | **New.** Animation overlay (`Clock`, `FrameRequester`, `Tween`/`Transition` helpers, `DOTS_NO_ANIM` gate) | 2 |
| `rust/installer-tui/src/ui.rs` | **Full rewrite.** `App` → abstracttui `View` projection per `Screen` | 3,4,5,6 |
| `rust/installer-tui/src/main.rs` | **Rewrite.** abstracttui runtime + custom loop + mpsc worker bridge + reboot | 7 |
| `rust/installer-tui/src/lib.rs` | Re-export `input`, `fx`, keep `app`/`ui` | 1,2 |
| `rust/installer-tui/tests/app.rs` | 2-line `use` swap | 1 |
| `rust/installer-tui/tests/view.rs` | **New.** Headless render + `Clock::fixed` animation tests | 3,4,5,6,8 |

---

### Task 0: API spike + authoritative reference

**Goal:** Build a throwaway example that compiles and runs headless against the real `abstracttui 0.2.x` crate, exercising every API the migration needs, and paste the confirmed signatures into `docs/superpowers/refs/abstracttui-api.md`. This task is the source of truth for all later tasks. The compiler, not docs.rs summaries, decides the API.

**Files:**
- Create: `rust/installer-tui/examples/spike.rs`
- Create: `docs/superpowers/refs/abstracttui-api.md`
- Modify: `rust/installer-tui/Cargo.toml` (add `abstracttui = "0.2"`; keep `ratatui`/`crossterm` for now. Removed in Task 1)

**Interfaces:**
- Produces: `docs/superpowers/refs/abstracttui-api.md`, every signature later tasks reference.
- Produces: a compiling `examples/spike.rs` proving the signatures.

- [ ] **Step 1: Add abstracttui to Cargo.toml**

```toml
[dependencies]
abstracttui = "0.2"
ratatui = "0.29"   # removed in Task 1
crossterm = "0.28" # removed in Task 1
serde_json = "1"
anyhow = "1"

[[example]]
name = "spike"
```

- [ ] **Step 2: Write the spike example**

`rust/installer-tui/examples/spike.rs`. Exercise: `App::new(Size{...})` + `mount` + custom loop using `app.pump(...)`/`app.draw(...)` + `app.quit_requested()`; `Scope::signal` + `Signal::{get,set,update}`; `dyn_view(Style, || View)`; `Element::new().style(Style::row().gap(1)).focusable().on_event(|_cx, ev| if let UiEvent::Key(k) = ev { if k.key == Key::Char('q') { quit } }).child(...).build()`; the widget constructors `Block::new`, `List::new`, `Progress::new`, `Spinner::new`, `RichTextView::new` (find the real constructors by trying the documented idiom, the compiler corrects you); `Image` with `ImageFit`/`ImageAlign` on a `Bitmap::from_pixels(w,h,px)` built from a 2×2 RGBA buffer (construct `Rgba` by trying `Rgba::new(r,g,b,a)`, then the tuple-struct fallback); `Tween::new(0.0f32,1.0,ms(200)).with_easing(Easing::EaseOut).sample(ms(100))` and `Transition::new(0.0, ms(100), Easing::Linear).set_target(1.0, ms(0)).tick(ms(50)).value()`; headless `CaptureTerm` + `driver.turn(&mut app, &mut term)` + `assert_snapshot`.

```rust
//! Throwaway abstracttui API probe. Delete after the migration lands.
use abstracttui::prelude::*;
// Confirm exact imports needed (engine types not in prelude). Add here:
// use abstracttui::app::App; use abstracttui::gfx::Bitmap; use abstracttui::base::Rgba;
// use abstracttui::anim::{Tween, Transition, Easing, Clock}; use abstracttui::testing::CaptureTerm;

fn main() -> anyhow::Result<()> {
    // TODO probe: fill in from docs.rs until `cargo run --example spike` works.
    //   1. App::new(viewport) + mount(root) + custom loop with pump/draw + quit
    //   2. Signal<App_like> + dyn_view projection + key handler mutating the signal
    //   3. Block + List + Progress + Spinner + RichTextView + Image(mosaic)
    //   4. Bitmap::from_pixels from a 2x2 RGBA buffer
    //   5. Tween/Transition sampling
    //   6. CaptureTerm headless render + assert_snapshot
    Ok(())
}
```

This stub is intentional: the *work* of this task is iterating against `cargo run --example spike` and the docs.rs **source-view** pages (`https://docs.rs/abstracttui/0.2.24/src/abstracttui/<module>/<file>.rs.html`) until it compiles and runs headless. Replace the `TODO probe` body with the real exercising code.

- [ ] **Step 3: Iterate until `cargo run --example spike` works headless**

Run: `cd rust/installer-tui && cargo run --example spike`
Expected: compiles, runs without a real terminal (drive `CaptureTerm` for the headless path, or exit 0 immediately for the live path). Use the docs.rs **source-view** URLs (`/src/abstracttui/...`) to read exact signatures. They are static HTML, unlike the JS-rendered struct pages.

- [ ] **Step 4: Record confirmed signatures into the reference doc**

Write `docs/superpowers/refs/abstracttui-api.md` with one section per concern, each with verbatim confirmed signatures and a 1-line idiom copied from `spike.rs`:

- **Runtime & custom loop:** `App::new`, `mount` (root signature), the per-iteration call(s) (`pump`/`draw`/`turn`), `quit_requested()`, `quitter()`, `Size` constructor.
- **Reactive:** `Scope::signal`, `Signal::{get,set,update,get_untracked}`, `provide_context`/`use_context`, `Scope::child`.
- **View tree:** `Element::new` + chain, `dyn_view` exact signature, `View` from `.build()`, `UiEvent`/`Key` variants used, `on_event`/`on_key` handler signature.
- **Layout Style:** `Style::{row,column,default}`, fields/builder methods actually used (`gap`, `padding`, `margin`, `align`, `justify`, `width`, `height`), `Direction`, `Track` variants.
- **Widgets:** `Block::new` + border/title/focus methods, `List::new` + items/state/highlight/selectable/on_select, `Progress::new` + ratio/label, `Spinner::new` + `SpinnerKind`, `RichTextView::new` + wrap/align, `Image::new` + bitmap/fit/align/mosaic, `ImageFit`/`ImageAlign` variants.
- **Gfx:** `Bitmap::{new,from_pixels,from_fn}`, `Rgba` constructor, `resize_*`.
- **Anim:** `Clock::{real,fixed}`, `Tween::new`/`sample`/`with_easing`, `Transition::new`/`set_target`/`tick`/`value`, `Easing` variants, `FrameRequester` (how to request a frame), `ms(...)` constructor, `particles::Burst`.
- **Testing:** `CaptureTerm` construction, scripted input, `driver.turn`/`app.pump`/`app.draw`, reading rendered cells/text, `assert_snapshot` + `UPDATE_GOLDENS=1`, `Clock::fixed` for deterministic anim tests.

- [ ] **Step 5: Verify reference is internally consistent**

Run: `cd rust/installer-tui && cargo check --example spike`
Expected: PASS (proves every signature in the reference compiles).

- [ ] **Step 6: Commit**

```bash
cd rust/installer-tui
git add Cargo.toml examples/spike.rs ../../docs/superpowers/refs/abstracttui-api.md
git commit -m "feat(installer-tui): abstracttui API spike + reference"
```

---

### Task 1: Dependency swap + `input` shim + state-machine type fix

**Goal:** Remove `ratatui`/`crossterm`, introduce the engine-agnostic `input` shim, switch `App::handle_key` to it, and fix `tests/app.rs` with a 2-line `use` swap, so the state-machine test suite is green again on the new deps.

**Files:**
- Modify: `rust/installer-tui/Cargo.toml`
- Create: `rust/installer-tui/src/input.rs`
- Modify: `rust/installer-tui/src/app.rs` (lines 4, 123, 193-area imports only, logic unchanged)
- Modify: `rust/installer-tui/src/lib.rs`
- Modify: `rust/installer-tui/tests/app.rs` (lines 3, 9-11)

**Interfaces:**
- Consumes: `docs/superpowers/refs/abstracttui-api.md` (not needed yet, no abstracttui code in this task).
- Produces: `pub mod input; pub use input::{KeyCode, KeyEvent};` exported from `dots_installer`. `App::handle_key(&mut self, key: input::KeyEvent)`.

- [ ] **Step 1: Write the failing test edit (test currently won't compile after dep removal)**

Edit `rust/installer-tui/tests/app.rs` line 3 and the `key` helper (lines 9-11):

```rust
use dots_installer::input::{KeyCode, KeyEvent};
// …
fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::from(code)
}
```

(All call sites, such as `key(KeyCode::Char(c))`, `key(KeyCode::Enter)`, etc., stay byte-identical.)

- [ ] **Step 2: Write the `input` shim**

`rust/installer-tui/src/input.rs`:

```rust
//! Engine-agnostic key-event types for the wizard state machine.
//!
//! `App::handle_key` is a pure transition function deliberately kept free of
//! any TUI engine dependency, so the state machine stays unit-testable without
//! a terminal. `main.rs` converts abstracttui's key events into these at the
//! bridge; tests construct them directly.

/// The subset of keys the wizard reacts to. Variant names mirror the
/// `crossterm` names the tests already use, so existing call sites are
/// unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCode {
    Char(char),
    Enter,
    Esc,
    Backspace,
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub code: KeyCode,
}

impl From<KeyCode> for KeyEvent {
    fn from(code: KeyCode) -> Self {
        Self { code }
    }
}
```

- [ ] **Step 3: Swap `app.rs`'s key type**

In `rust/installer-tui/src/app.rs`:
- Remove `use crossterm::event::{KeyCode, KeyEvent};` (line 4).
- Add `use crate::input::{KeyCode, KeyEvent};`.
- Change `pub fn handle_key(&mut self, key: KeyEvent)` to `pub fn handle_key(&mut self, key: crate::input::KeyEvent)`. But since both are now `crate::input::KeyEvent` via the `use`, the signature text `key: KeyEvent` already refers to the right type. No body changes.

- [ ] **Step 4: Export `input` from the lib**

`rust/installer-tui/src/lib.rs`. Add `pub mod input;` (keep existing `pub mod app;` etc.).

- [ ] **Step 5: Swap Cargo.toml deps**

```toml
[dependencies]
abstracttui = "0.2"
serde_json = "1"
anyhow = "1"
```

(Drop `ratatui` and `crossterm`.) Remove the `[[example]]` block from Task 0 if you don't want it shipped, but keeping `examples/spike.rs` is harmless; leave it.

- [ ] **Step 6: Run the state-machine tests, must pass**

Run: `cd rust/installer-tui && cargo test --test app`
Expected: PASS, all ~70 `handle_key` call sites compile and behave identically.

- [ ] **Step 7: Confirm the rest still compiles (ui.rs/main.rs will be broken, expected)**

Run: `cd rust/installer-tui && cargo check`
Expected: FAIL only in `ui.rs` and `main.rs` (still reference `ratatui`/`crossterm`). That's fine. They're rewritten in Tasks 3-7. Do **not** commit a green `cargo check` yet; commit after the test passes.

- [ ] **Step 8: Commit**

```bash
cd rust/installer-tui
git add Cargo.toml src/input.rs src/app.rs src/lib.rs tests/app.rs
git commit -m "refactor(installer-tui): engine-agnostic input shim, drop ratatui/crossterm"
```

---

### Task 2: `fx` animation overlay skeleton

**Goal:** Create `src/fx.rs` with the animation primitives the UI will use, gated by `DOTS_NO_ANIM`, and unit-test the tween/transition math with `Clock::fixed`. No UI wiring yet.

**Files:**
- Create: `rust/installer-tui/src/fx.rs`
- Modify: `rust/installer-tui/src/lib.rs` (export `fx`)
- Test: `rust/installer-tui/tests/fx.rs`

**Interfaces:**
- Consumes: `abstracttui::anim` signatures from `docs/superpowers/refs/abstracttui-api.md`.
- Produces: `pub fn animations_enabled() -> bool` (env gate); `pub struct Fx` holding the runtime `Clock` + the live `Transition`/`Tween` values; methods `screen_offset(&self) -> f32`, `progress_ratio(&self, target: f64) -> f32`, `shake_offset(&self) -> i32`, plus `pub fn burst_done(&self)` flag.

- [ ] **Step 1: Write the failing animation-math test**

`rust/installer-tui/tests/fx.rs`:

```rust
//! Animation-math tests using abstracttui's fixed clock for determinism.
use abstracttui::anim::Clock;
use dots_installer::fx::{ease_ratio, shake_at};

#[test]
fn ease_ratio_eases_out_and_clamps() {
    let clock = Clock::fixed();
    let r = ease_ratio(clock, 0.0_f64, 1.0, 200);
    // at t=0 the eased value is 0; at t>=duration it is 1; mid is > 0.5 (ease-out)
    assert!((r.now(0).abs()) < 1e-6);
    assert!((r.now(200) - 1.0).abs() < 1e-6);
    assert!(r.now(100) > 0.5);
}

#[test]
fn shake_decays_to_zero_after_duration() {
    let clock = Clock::fixed();
    let s = shake_at(clock, 120);
    assert_eq!(s.now(0).abs(), 0); // no shake at the instant it starts? see impl
    assert_eq!(s.now(121), 0);     // after duration: settled
}

#[test]
fn animations_enabled_respects_env() {
    std::env::set_var("DOTS_NO_ANIM", "1");
    assert!(!dots_installer::fx::animations_enabled());
    std::env::remove_var("DOTS_NO_ANIM");
    assert!(dots_installer::fx::animations_enabled());
}
```

Adjust the exact `Clock::fixed` / `now(ms)` API to match the reference doc. The spike (Task 0) confirmed the real `Clock` API. If `Clock::fixed` doesn't take `ms`-args the way shown, use the confirmed form and update the test to match; the *property* under test (ease-out front-loads, clamps at 1, shake settles) is the contract.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust/installer-tui && cargo test --test fx`
Expected: FAIL, `dots_installer::fx` doesn't exist.

- [ ] **Step 3: Implement `fx.rs`**

`rust/installer-tui/src/fx.rs`. Use the `Tween`/`Transition`/`Easing`/`Clock`/`FrameRequester` signatures confirmed in the reference. The shape:

```rust
//! Animation overlay for the installer TUI. All motion is opt-in and
//! collapses to a no-op when `DOTS_NO_ANIM` is set or the terminal reports
//! degraded capabilities (handled by the caller via `use_caps`).
use abstracttui::anim::{Clock, Easing, FrameRequester, Transition, Tween};

/// True unless `DOTS_NO_ANIM` is set.
pub fn animations_enabled() -> bool {
    std::env::var("DOTS_NO_ANIM").is_err()
}

/// A `Transition` retargeted toward `target`, eased over `dur_ms`.
pub struct ScreenFx {
    clock: Clock,
    screen_offset: Transition<f32>,   // panel slide x-offset
    progress: Transition<f32>,        // eased progress fill
    shake: Option<Tween<i32>>,         // one-shot error shake, set on error
    requester: FrameRequester,
}

impl ScreenFx {
    pub fn new(clock: Clock) -> Self { /* init transitions at 0, requester */ todo_build_from_reference() }

    /// Retarget the screen slide (called on `Screen` change).
    pub fn retarget_screen(&self, _to: f32) { self.screen_offset.set_target(_to, ms(180)); self.request(); }

    /// Retarget the progress fill (called when `current_step`/`total_steps` change).
    pub fn retarget_progress(&self, ratio: f32) { self.progress.set_target(ratio, ms(160)); self.request(); }

    /// Fire a one-shot error shake.
    pub fn shake(&mut self) { self.shake = Some(Tween::new(0, 0, ms(120)).with_easing(Easing::EaseOut)); self.request(); }

    pub fn screen_offset(&self) -> f32 { self.screen_offset.value() }
    pub fn progress_ratio(&self) -> f32 { self.progress.value() }
    pub fn shake_offset(&self) -> i32 { self.shake.as_ref().map(|t| t.sample(self.clock.now())).unwrap_or(0) }

    fn request(&self) { if animations_enabled() { self.requester.request(); } }
}
```

Replace `todo_build_from_reference()` and the `Transition`/`Tween`/`Clock::now`/`FrameRequester::request` calls with the confirmed signatures from `docs/superpowers/refs/abstracttui-api.md`. The `ease_ratio`/`shake_at` free helpers used by the test wrap `Tween` directly:

```rust
pub struct EaseProbe { t: Tween<f32> }
impl EaseProbe { pub fn now(&self, ms: u64) -> f32 { self.t.sample(Ms::from_millis(ms)) } }
pub fn ease_ratio(_clock: Clock, from: f64, to: f64, dur_ms: u64) -> EaseProbe {
    EaseProbe { t: Tween::new(from as f32, to as f32, ms(dur_ms)).with_easing(Easing::EaseOut) }
}
pub fn shake_at(_clock: Clock, dur_ms: u64) -> EaseProbe {
    EaseProbe { t: Tween::new(0.0, 0.0, ms(dur_ms)) } // amplitude handled by the sine sampler
}
```

(Use the real `ms(...)`/duration constructor from the reference; `f32` vs `f64` per the reference's `Lerp` impl.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust/installer-tui && cargo test --test fx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/installer-tui
git add src/fx.rs src/lib.rs tests/fx.rs
git commit -m "feat(installer-tui): fx animation overlay skeleton (DOTS_NO_ANIM-gated)"
```

---

### Task 3: `ui.rs`, wizard text screens

**Goal:** Rewrite `ui.rs` from scratch as an abstracttui View projection. Start with the text-only wizard screens (Welcome, Hostname, Username, GitName, GitEmail, RootPassword*, UserPassword*, Confirm) using a centered `Block` + `RichTextView` prompt + a styled input line with a cursor glyph, plus the error line. Verify with a headless render test.

**Files:**
- Modify: `rust/installer-tui/src/ui.rs` (full rewrite, starting fresh)
- Test: `rust/installer-tui/tests/view.rs` (new)

**Interfaces:**
- Consumes: `App`, `Screen` from `crate::app`; `input` not needed here; widget + `Style` + `dyn_view` + `Scope`/`Signal` signatures from `docs/superpowers/refs/abstracttui-api.md`; the Tokyonight palette constants from the old `ui.rs` (keep them, ported to `render::Rgba`/theme tokens).
- Produces: `pub fn root_view(cx: Scope, app: Signal<App>) -> View`, the root component. `pub mod palette` (Tokyonight colors as `Rgba` consts / theme tokens).

- [ ] **Step 1: Write the failing headless render test for the Welcome screen**

`rust/installer-tui/tests/view.rs`:

```rust
//! Headless render tests for the installer TUI view.
use abstracttui::testing::{CaptureTerm, assert_snapshot};
use dots_installer::app::{App, Screen};
use dots_installer::ui;

fn render_to_string(app: &App, cols: u16, rows: u16) -> String {
    // Build a CaptureTerm of cols×rows, mount ui::root_view over a Signal<App>
    // set to `app.clone()`, pump one frame, and return the rendered text.
    // Exact harness per docs/superpowers/refs/abstracttui-api.md §Testing.
    todo_harness_from_reference()
}

#[test]
fn welcome_screen_renders_title_and_hint() {
    let app = App::new(vec![], Some("/dev/nvme0n1".into()));
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("tokyonight-dots installer"));
    assert!(out.contains("Enter continue"));
}
```

`App` is `Clone`? It currently isn't derived. Add `#[derive(Debug, Clone)]` to `App` in `app.rs` (it owns only `Clone`able fields, but verify). The test clones `App` into the signal. Implement `todo_harness_from_reference()` using the `CaptureTerm` + `driver.turn`/`app.pump` + `assert_snapshot` API confirmed in the reference; if reading raw rendered text has a documented accessor, use it, else compare via `assert_snapshot` against a golden (with `UPDATE_GOLDENS=1` to seed).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust/installer-tui && cargo test --test view -- welcome_screen_renders_title_and_hint`
Expected: FAIL, `ui::root_view` doesn't exist / harness stub.

- [ ] **Step 3: Port the palette and write `root_view` + the text screens**

`rust/installer-tui/src/ui.rs`, starting with:

```rust
//! abstracttui view. Pure projection of &App onto a View tree. No I/O.
//! Reactivity comes from `dyn_view` re-reading the `Signal<App>` on change.
use abstracttui::prelude::*;
use crate::app::{App, Screen};
use crate::fx::ScreenFx;

/// Tokyonight (night) palette as engine Rgba values (no hex arithmetic in widgets).
pub mod palette {
    use abstracttui::base::Rgba;
    pub const BG: Rgba = Rgba::new(0x1a, 0x1b, 0x26);
    pub const FG: Rgba = Rgba::new(0xc0, 0xca, 0xf5);
    pub const BLUE: Rgba = Rgba::new(0x7a, 0xa2, 0xf7);
    pub const CYAN: Rgba = Rgba::new(0x7d, 0xcf, 0xff);
    pub const GREEN: Rgba = Rgba::new(0x9e, 0xce, 0x6a);
    pub const MAGENTA: Rgba = Rgba::new(0xbb, 0x9a, 0xf7);
    pub const RED: Rgba = Rgba::new(0xf7, 0x76, 0x8e);
    pub const YELLOW: Rgba = Rgba::new(0xe0, 0xaf, 0x68);
    pub const DIM: Rgba = Rgba::new(0x56, 0x5f, 0x89);
}

/// Root component: one `dyn_view` that re-reads `app` and dispatches by `Screen`.
pub fn root_view(cx: Scope, app: Signal<App>, fx: Signal<ScreenFx>) -> View {
    Element::new()
        .style(Style::default())  // full screen; bg fill via a draw closure or Block
        .child(dyn_view(Style::default(), move || {
            let a = app.get();
            match a.screen {
                Screen::Installing => installing_view(&a),
                Screen::Failed => failed_view(&a),
                _ => wizard_view(&a),
            }
        }))
        .build()
}
```

Then implement `wizard_view(&App) -> View`: a centered `Block` (title from the match in the old `ui.rs`, bottom hint) containing a `RichTextView` built from the prompt lines, the input line `> {shown}█` in CYAN, and the error line in RED. Use `input_lines(prompt, input, mask)` ported to return `RichText`/spans. Center via `Style` absolute positioning or margin-auto per the reference's confirmed centering idiom. For the text screens the `title`/`hint`/`prompt` strings are copied **verbatim** from the old `ui.rs` `match` arms (Welcome, Hostname, Username, GitName, GitEmail, RootPassword, RootPasswordConfirm, UserPassword, UserPasswordConfirm, Confirm). Preserve every string.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd rust/installer-tui && cargo test --test view -- welcome_screen_renders_title_and_hint`
Expected: PASS.

- [ ] **Step 5: Add render tests for one input screen and the error line**

```rust
#[test]
fn hostname_screen_shows_prompt_and_input_cursor() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Hostname;
    app.input = "desk".into();
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("Hostname"));
    assert!(out.contains("desk"));        // input echoed
}

#[test]
fn confirm_screen_shows_erase_prompt_and_typed_text() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Confirm;
    app.input = "ERA".into();
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("ERASE"));
    assert!(out.contains("ERA"));
}
```

Implement until both pass.

- [ ] **Step 6: Commit**

```bash
cd rust/installer-tui
git add src/ui.rs src/app.rs tests/view.rs
git commit -m "feat(installer-tui): abstracttui view for wizard text screens"
```

---

### Task 4: `ui.rs`, Network / DiskSelect / WifiPassword / WifiConnecting

**Goal:** Add the interactive-list screens using abstracttui's `List` widget (Network's Wi-Fi list, DiskSelect's multi-select with `[x]`/`[ ]`) and the `Spinner`-driven busy states. Keep ASCII markers for raw-tty1 safety.

**Files:**
- Modify: `rust/installer-tui/src/ui.rs` (extend `wizard_view`'s match)
- Test: `rust/installer-tui/tests/view.rs` (extend)

**Interfaces:**
- Consumes: `List`/`Spinner`/`Progress` APIs from the reference; `app.wifi_networks`, `app.wifi_selected`, `app.disks`, `app.picked`, `app.selected`, `app.net_busy`.
- Produces: `fn network_view(&App) -> View`, `fn disk_select_view(&App) -> View`, `fn wifi_connecting_view(&App) -> View`.

- [ ] **Step 1: Write failing render tests**

```rust
#[test]
fn network_screen_lists_wifi_networks_with_selection_marker() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Network;
    app.wifi_networks = vec![
        dots_installer::net::WifiNetwork { ssid: "home".into(), signal: 80, security: "WPA2".into() },
        dots_installer::net::WifiNetwork { ssid: "cafe".into(), signal: 40, security: String::new() },
    ];
    app.wifi_selected = 0;
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("home"));
    assert!(out.contains("cafe"));
    assert!(out.contains("WPA2"));
}

#[test]
fn disk_select_shows_picked_disks_with_ascii_marker() {
    let mut app = App::new(vec![
        dots_installer::disks::Disk { path: "/dev/vda".into(), size_bytes: 64*1024*1024*1024, model: "VMware".into(), removable: false },
    ], None);
    app.screen = Screen::DiskSelect;
    app.picked = vec![true];
    app.selected = 0;
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("/dev/vda"));
    assert!(out.contains("[x]"));   // ASCII marker preserved for raw tty1
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: FAIL.

- [ ] **Step 3: Implement the list screens**

Extend `wizard_view`'s match with `Screen::Network => network_view(&a)`, `Screen::DiskSelect => disk_select_view(&a)`, `Screen::WifiConnecting => wifi_connecting_view(&a)`, `Screen::WifiPassword => input_lines(...)` (already a text screen, uses the input-line helper from Task 3). `network_view` builds a `List` from `app.wifi_networks` with the selected index highlighted (`app.wifi_selected`); render signal bars via `n.signal_bars()`; show `Spinner` when `app.net_busy.is_some()`. `disk_select_view` builds a `List` of disks with `[x]`/`[ ]` markers from `app.picked` (ASCII, not a unicode checkbox, for raw-VT font safety) and `▶`/` ` cursor from `app.selected`. `wifi_connecting_view` shows the connecting message + a `Spinner`. Copy all prompt/hint strings verbatim from the old `ui.rs`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/installer-tui
git add src/ui.rs tests/view.rs
git commit -m "feat(installer-tui): abstracttui List+Spinner for Network/DiskSelect/connecting"
```

---

### Task 5: `ui.rs`, Installing / Failed / Done

**Goal:** Add the `Installing` screen (animated `Progress` + log tail `Feed`/`RichTextView`), `Failed`, and `Done`. Wire `ScreenFx` retargets (progress eased; done burst) without full animation polish yet (Task 6 does polish).

**Files:**
- Modify: `rust/installer-tui/src/ui.rs`
- Test: `rust/installer-tui/tests/view.rs`

**Interfaces:**
- Consumes: `Progress`, `Feed`/`RichTextView`, `Spinner`; `app.current_step`, `app.total_steps`, `app.step_title`, `app.log`, `app.error`, `app.recovery_key`; `ScreenFx` from `crate::fx`.
- Produces: `fn installing_view(&App, &ScreenFx) -> View`, `fn failed_view(&App) -> View`, `fn done_view(&App) -> View`.

- [ ] **Step 1: Write failing render tests**

```rust
#[test]
fn installing_screen_shows_step_count_and_log_tail() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Installing;
    app.current_step = 2; app.total_steps = 5; app.step_title = "formatting".into();
    app.log.push("==> formatting".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("step 2/5"));
    assert!(out.contains("formatting"));
}

#[test]
fn done_screen_shows_recovery_key() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Done;
    app.recovery_key = Some("RECOVERY-1234".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("RECOVERY-1234"));
    assert!(out.contains("Enter reboot"));
}

#[test]
fn failed_screen_shows_error_message() {
    let mut app = App::new(vec![], Some("/dev/nvme0n1".into()));
    app.screen = Screen::Failed;
    app.error = Some("disk blew up".into());
    let out = render_to_string(&app, 80, 24);
    assert!(out.contains("disk blew up"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: FAIL.

- [ ] **Step 3: Implement the three screens**

`installing_view` splits vertically (flexbox `Style::column`): a `Progress` bar (ratio = `current_step/total_steps`, label `step {i}/{n} — {step_title}`) and a log tail `Feed`/`RichTextView` showing the last N lines of `app.log` in DIM. `failed_view` shows `app.error` in RED + the Ctrl+Alt+F2 hint + log tail. `done_view` shows the recovery key in YELLOW bold + the reboot hint. `root_view` passes `fx` into `installing_view` so the progress ratio can be eased (read `fx.progress_ratio()` if `animations_enabled()`, else the raw ratio), but the *retarget* calls happen in `main.rs` (Task 7) when install events arrive; here just read the value. Copy all strings verbatim from the old `ui.rs`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/installer-tui
git add src/ui.rs tests/view.rs
git commit -m "feat(installer-tui): abstracttui Installing/Failed/Done screens"
```

---

### Task 6: Wire animations

**Goal:** Connect `ScreenFx` to the view and the state transitions: screen slide/fade on `Screen` change, eased progress on install step changes, error shake on `app.error` becoming set, and the done `Burst`.

**Files:**
- Modify: `rust/installer-tui/src/ui.rs` (apply `fx` offsets in `wizard_view`/`installing_view`)
- Modify: `rust/installer-tui/tests/view.rs`

**Interfaces:**
- Consumes: `ScreenFx` (Task 2); `Screen` change detection (compare previous vs current screen inside the `dyn_view` via a `Memo<Screen>` or a `Signal<Screen>` kept in the root scope).
- Produces: animated wizard panel (slide/fade), animated progress, shake on error, burst on Done.

- [ ] **Step 1: Write the animation test with `Clock::fixed`**

```rust
#[test]
fn screen_change_drives_slide_retarget() {
    // Mount root_view with a ScreenFx on a fixed clock; set the App signal to
    // Welcome, pump, then set it to Network, pump. Assert the ScreenFx's
    // screen_offset transition was retargeted (its target changed) by reading
    // the fx signal's exposed target or by snapshotting two frames and
    // confirming the panel x-offset differs between frames.
    todo_animation_harness_from_reference()
}

#[test]
fn error_becoming_set_fires_shake() {
    // Set error=None, pump; set error=Some("..."), pump. Assert fx.shake_offset()
    // is nonzero on the next frame and settles to 0 after the shake duration.
    todo_animation_harness_from_reference()
}
```

Implement `todo_animation_harness_from_reference()` per the reference's `Clock::fixed` + headless pump API.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: FAIL.

- [ ] **Step 3: Wire the animations**

In `root_view`, keep a `Signal<Screen>` (`last_screen`) and a `Signal<Option<String>>` (`last_error`) in the root scope. Inside the `dyn_view` closure, compare `a.screen` to `last_screen.get()`; on change call `fx.get().retarget_screen(...)` and update `last_screen`. Compare `a.error` to `last_error`; when a new `Some` appears call `fx.get().shake()` and update `last_error`. In `wizard_view`, apply `fx.screen_offset()` as a horizontal translate on the centered panel (via `Style` absolute x offset or a draw-closure translate per the reference) and reduce opacity for the fade (if the paint `Style` supports an alpha/attr; else skip fade and keep only the slide, confirm in the reference). In `installing_view`, use `fx.progress_ratio()` for the `Progress` fill. On `Screen::Done` entry, fire `fx.burst_done()` (a one-shot `particles::Burst` overlay via `Overlays`). All wrapped in `if animations_enabled()`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust/installer-tui && cargo test --test view`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd rust/installer-tui
git add src/ui.rs tests/view.rs
git commit -m "feat(installer-tui): wire screen slide/fade, eased progress, error shake, done burst"
```

---

### Task 7: `main.rs`, runtime + custom loop + worker bridge + reboot

**Goal:** Replace the ratatui/crossterm event loop with an abstracttui runtime: build `App`, wrap in `Signal<App>`, mount `root_view`, run a custom loop that drains the install/net `mpsc` channels into `on_install_event`/`on_net_event`, dispatches `pending_net_op`/`start_install` to worker threads, feeds engine key events into `handle_key`, and quits via `quitter` when `should_quit`. Reboot side effects unchanged.

**Files:**
- Modify: `rust/installer-tui/src/main.rs` (full rewrite)
- (No new test. This is wiring; the end-to-end smoke is manual via `DOTS_INSTALLER_DRY_RUN`.)

**Interfaces:**
- Consumes: `App::new`/`mount`/custom-loop pump/`quitter`/`quit_requested` from the reference; `ui::root_view`; `fx::ScreenFx`; `install::run`/`net::run_op` (unchanged signatures); `input::KeyEvent` conversion from abstracttui `UiEvent::Key`.
- Produces: a working `main.rs` that runs the installer TUI on abstracttui.

- [ ] **Step 1: Rewrite `main.rs`**

```rust
use dots_installer::{app, disks, fx::{self, ScreenFx}, install, net, ui, input};
use abstracttui::prelude::*;

fn main() -> anyhow::Result<()> {
    let swap_size_gib = install::swap_size_from_meminfo(
        &std::fs::read_to_string("/proc/meminfo").unwrap_or_default(),
    );
    let disks = disks::list_disks().unwrap_or_default();
    let auto = disks::autodetect_disk(&disks, swap_size_gib).ok().map(|d| d.path);
    let mut app_state = app::App::new(disks, auto);
    app_state.config.swap_size_gib = swap_size_gib;

    run(app_state)?;
    Ok(())
}

fn run(mut app_state: app::App) -> anyhow::Result<()> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (net_tx, net_rx) = std::sync::mpsc::channel();
    let mut runner_started = false;

    // abstracttui owns raw mode + alt screen + its own panic hook.
    let mut engine = App::new(viewport_80x24_or_detected());     // reference: Size constructor
    let cx = /* root scope from engine, see reference */ todo_root_scope();
    let app_sig = cx.signal(app_state.clone());
    let fx_sig = cx.signal(ScreenFx::new(/* Clock::real() */ todo_clock()));
    engine.mount(ui::root_view(cx, app_sig, fx_sig))?;

    while !engine.quit_requested() {
        // 1. drain install worker results
        while let Ok(ev) = rx.try_recv() {
            app_state.on_install_event(ev);
        }
        while let Ok(ev) = net_rx.try_recv() {
            app_state.on_net_event(ev);
        }
        // 2. dispatch pending net op / install runner
        if app_state.start_install && !runner_started {
            runner_started = true;
            let cfg = app_state.config.clone();
            let tx = tx.clone();
            std::thread::spawn(move || install::run(cfg, tx));
        }
        if let Some(op) = app_state.pending_net_op.take() {
            let tx = net_tx.clone();
            std::thread::spawn(move || net::run_op(op, &tx));
        }
        // 3. publish state to the view
        app_sig.set(app_state.clone());
        // 4. advance the engine one step (input + effects + layout + render).
        //    Per docs/superpowers/refs/abstracttui-api.md §Runtime, use the
        //    confirmed pump/turn call with a short timeout so worker results
        //    land within ~100 ms even with no key input.
        todo_pump_one_step(&mut engine); // reference: app.pump(...) / driver.turn(...)
        // 5. the engine's key handler (mounted in root_view) calls
        //    app.handle_key(input::KeyEvent{...}) and set's the signal; after
        //    the pump, re-read the possibly-mutated app back.
        app_state = app_sig.get();
    }

    if app_state.reboot && std::env::var("DOTS_INSTALLER_DRY_RUN").is_err() {
        let _ = std::process::Command::new("systemctl").arg("reboot").status();
    }
    Ok(())
}
```

Resolve every `todo_*` against `docs/superpowers/refs/abstracttui-api.md`. The key bridge (`root_view`'s `on_event`) converts abstracttui's `UiEvent::Key(k)` to `input::KeyEvent`:

```rust
// inside root_view's root Element::on_event:
.on_event(move |_, ev| {
    if let UiEvent::Key(k) = ev {
        if let Some(code) = map_key(&k.key) {
            let mut a = app.get();
            a.handle_key(input::KeyEvent::from(code));
            app.set(a);
            if app.get().should_quit { quit.set(()); }  // or engine.quitter()
        }
    }
})
```

`map_key(&Key) -> Option<input::KeyCode>` maps `Key::Char(c)`→`Char(c)`, `Enter`→`Enter`, `Esc`→`Esc`, `Backspace`→`Backspace`, `Up`→`Up`, `Down`→`Down`; `None` for everything else (the wizard ignores unknown keys). Confirm the real `Key` variant names from the reference.

- [ ] **Step 2: Verify it compiles**

Run: `cd rust/installer-tui && cargo check`
Expected: PASS (first full green `cargo check` since Task 1).

- [ ] **Step 3: Manual smoke test (dry run)**

Run: `cd rust/installer-tui && DOTS_INSTALLER_DRY_RUN=1 cargo run`
Expected: the wizard renders; you can walk Welcome → Network (skip with `s`) → Hostname → … → Confirm (type `ERASE`) → Installing (install::run will fail harmlessly under DRY_RUN / no disks) → q/Esc exits cleanly, terminal restored, **no reboot**. If `install::run` errors, it lands on the Failed screen. That's fine, the loop still drains and quits on `q`.

- [ ] **Step 4: Run the full test suite**

Run: `cd rust/installer-tui && cargo test && cargo fmt --all && cargo clippy -- -W clippy::all -W clippy::perf -W clippy::pedantic`
Expected: all tests PASS, fmt clean, clippy clean.

- [ ] **Step 5: Commit**

```bash
cd rust/installer-tui
git add src/main.rs
git commit -m "feat(installer-tui): abstracttui runtime + custom loop + mpsc worker bridge"
```

---

### Task 8: Full headless render + animation test suite

**Goal:** Harden `tests/view.rs` into a complete suite covering every screen + the animation properties, replacing the per-task ad-hoc tests with a coherent set. Confirm golden snapshots where useful.

**Files:**
- Modify: `rust/installer-tui/tests/view.rs`

**Interfaces:**
- Consumes: everything above.
- Produces: a green `tests/view.rs` covering every screen.

- [ ] **Step 1: Consolidate the test suite**

Ensure `tests/view.rs` has a render test for each `Screen` variant (Welcome, Network, WifiPassword, WifiConnecting, DiskSelect, Hostname, Username, GitName, GitEmail, RootPassword, RootPasswordConfirm, UserPassword, UserPasswordConfirm, Confirm, Installing, Done, Failed) asserting the title/hint/key strings from the old `ui.rs`, plus the two animation tests from Task 6. Use `assert_snapshot` for one or two representative screens (Welcome, Installing) with `UPDATE_GOLDENS=1` to seed.

- [ ] **Step 2: Run the full suite**

Run: `cd rust/installer-tui && cargo test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd rust/installer-tui
git add tests/view.rs
git commit -m "test(installer-tui): full headless render + animation suite"
```

---

## Notes for the executor

- The spike (Task 0) is non-negotiable: every `todo_*` and "confirm from the reference" in later tasks resolves against `docs/superpowers/refs/abstracttui-api.md`, which the spike produced and the compiler verified. Do **not** guess signatures. If the reference is silent, extend the spike and update the reference.
- `cargo check` after Task 1 will be red in `ui.rs`/`main.rs` until Tasks 3-7 land. That's expected. Commit Task 1 after `cargo test --test app` passes, not after a full green `cargo check`.
- Preserve every user-visible string from the old `ui.rs` verbatim (titles, hints, prompts, error messages). The render tests assert on them.
- Keep `examples/spike.rs` in the repo until the migration is fully green; it's a useful regression probe. Remove it in a final cleanup commit if desired.