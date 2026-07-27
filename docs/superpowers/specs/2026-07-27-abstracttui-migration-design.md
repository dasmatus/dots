# Migrate the TUI crates from `ratatui` to `abstracttui`

- **Date:** 2026-07-27
- **Status:** Approved (design)
- **Scope:** `rust/installer-tui`, `rust/wallpaper-tui`
- **Out of scope:** `rust/hyprmon` (no TUI — `clap` CLI)
- **Target crate:** [`abstracttui` 0.2.x](https://docs.rs/abstracttui) (MIT, reactive compositor-grade terminal UI engine)

## 1. Goal

Rewrite every TUI utility in the two TUI crates to `abstracttui`, lean into its
idioms (flexbox layout, reactive `dyn_view` regions, capability-honest
rendering, `anim` tweens/transitions), and add tasteful animations — while
preserving the existing pure state machines and their tests.

## 2. Decisions (locked)

| Decision | Choice |
|---|---|
| Migration breadth | Full TUI layer in **both** crates (`ui.rs` + `main.rs` + key-event type in `app.rs`) |
| Parity | Behavioral parity for flow/keys/text; **UX improvements allowed**; **animations added** |
| Bridge architecture | **A — pure state machine + reactive projection** (keep `App` pure; hold in one `Signal<App>`; `dyn_view` projects to widgets) |
| Key-event type | Crate-local `input::{KeyCode, KeyEvent}` shim; fully removes `crossterm` |
| Wallpaper preview rendering | **Mosaic/emulator backend** (cell-grid glyphs), no native image-protocol negotiation |
| Animations on raw `tty1` | **On by default**, capability-honest fallback to cheap/ASCII via `use_caps` |
| `DOTS_NO_ANIM` escape hatch | **Included** (env-gated; disables all `anim` overlay) |
| Non-TUI modules | **Untouched** (`config`, `disks`, `net`, `install`, `awww`, `accent`, `tint`, `preview`, `wallpapers`, `cli`) |

## 3. Current state (what exists)

Both crates share the same architecture:

- **`app.rs`** — a pure state machine. `App::handle_key` is a pure transition
  function; `on_install_event` / `on_net_event` (installer) and `on_event`
  (wallpaper) drain worker results. Doc comments state this is deliberately
  pure so it is "unit-testable without a terminal."
- **`ui.rs`** — `draw(f: &mut Frame, app)` and helpers; pure projection of
  `&App` onto ratatui widgets (`Block`, `Paragraph`, `List`, `Gauge`,
  `StatefulImage`).
- **`main.rs`** — terminal setup (raw mode + alt screen via crossterm), an
  event loop that draws each frame, drains `mpsc` worker channels, dispatches
  `pending`/`pending_net_op` to worker threads, and polls `crossterm::event`
  with a 100 ms timeout. Panic hook restores the terminal.

`installer-tui/tests/app.rs` (≈500 lines, ~70 `handle_key` calls) pins the
state machine: it constructs `crossterm::event::{KeyCode, KeyEvent}` via a
`key()` helper, sets `App` fields directly (`app.screen = …`,
`app.wifi_networks = …`), and asserts screen transitions. `wallpaper-tui` has
no `app` state-machine test; its tests cover only the non-TUI modules.

## 4. Target architecture

### 4.1 The `input` shim (new, ~40 lines per crate)

`src/input.rs`:

```rust
pub enum KeyCode { Char(char), Enter, Esc, Backspace, Up, Down }
pub struct KeyEvent { pub code: KeyCode }
impl From<KeyCode> for KeyEvent { … }   // so tests keep KeyEvent::from(code)
```

Mirrors the crossterm variant names actually used. The bridge maps
abstracttui's key event → this enum. The state machine depends on **no** TUI
engine. `app.rs` switches its `handle_key` parameter from
`crossterm::event::KeyEvent` to `input::KeyEvent` (logic unchanged).

### 4.2 State ↔ reactive bridge (`main.rs`)

- `App::new(...)` as today; wrap in `cx.signal(app)`.
- Root component: `dyn_view(layout, |cx| build_view(cx, &app_sig))` — reads
  `App`, returns the View tree for the current `Screen` (installer) / main
  layout (wallpaper).
- **Key routing:** a root-level key handler converts the abstracttui key event
  → `input::KeyEvent`, calls `app.handle_key(...)`, and `set`s the signal.
  Text-input fields keep using `app.input` + our own char/backspace handling
  (rendered via a styled text element with a cursor glyph) — preserves the
  `app.input` semantics the tests assume. No `TextInput` widget coupling.
- **Worker bridge:** custom loop using `App::new` + manual `turn` +
  `wait_for_activity(timeout)`. Each turn:
  1. drain worker channels → `on_install_event`/`on_net_event` (installer) or
     `on_event` (wallpaper); `set` the signal;
  2. dispatch `pending_net_op`/`pending` to worker threads (same `mpsc` +
     `std::thread::spawn` pattern as today);
  3. the engine's own input path delivers key events into the key handler.
  - Quit via `App::quitter()` when `app.should_quit`.
  - Panic hook restores the terminal (abstracttui installs its own; we keep
    alt-screen/raw-mode restore on panic for safety).
- **Reboot/exit side effects (installer):** unchanged — driven by
  `app.reboot`/`should_quit` after the loop. `DOTS_INSTALLER_DRY_RUN` honored.

### 4.3 View layer — `installer-tui/src/ui.rs`

Tokyonight palette carried as an abstracttui `TokenSet`/theme (no hex literals
in widget code — per the engine's `no_color_arithmetic_in_widgets` rule).

- **Wizard screens** (`Welcome`, `Network`, `WifiPassword`, `WifiConnecting`,
  `DiskSelect`, `Hostname`, `Username`, `GitName`, `GitEmail`, `RootPassword*`,
  `UserPassword*`, `Confirm`, `Done`): centered `Block` (border + title +
  bottom hint) containing a `RichTextView` of prompt lines + a styled input
  line with cursor glyph; error line in red. Layout via `LayoutStyle`
  flexbox / absolute centering.
- **Network:** `List` widget (replaces hand-rolled `▶` lines) with highlight +
  selectable; `Spinner` driven by `net_busy`.
- **DiskSelect:** `List` with `[x]`/`[ ]` markers. Keep ASCII markers (raw-tty1
  safe) via `use_caps` fallback.
- **Installing:** `Progress` widget (sub-cell precision) for the step gauge +
  a `Feed`/`RichTextView` log tail (auto-tail last N lines). **Animated** fill.
- **Failed / Done:** `Block` + `RichTextView`.

### 4.4 View layer — `wallpaper-tui/src/ui.rs`

- Horizontal `List` (wallpapers) | `Image` preview pane, above an info bar,
  above a one-line help footer — flexbox `LayoutStyle`.
- **Preview:** worker decodes via existing `preview::load_preview` (returns
  `image::DynamicImage`; `tests/preview.rs` unchanged) → convert
  `img.to_rgba8()` → `abstracttui::gfx::Bitmap` on the UI thread → `Image`
  widget with `ImageFit`/`ImageAlign`. **Render via the mosaic/emulator
  backend** (half-block / quadrant / sextant / braille cell renderer) — i.e.
  skip native image-protocol negotiation (kitty/iTerm2/sixel) and force the
  cell-grid mosaic path. This **replaces** `ratatui_image::Picker` *and*
  removes the manual `from_query_stdio` DCS capability query (and its ACK-race
  workaround) entirely — the mosaic backend draws glyphs into the cell grid,
  so it works in any terminal emulator with no protocol detection.
- `use_caps(cx)` still chooses the safest `MosaicMode`: half-blocks on raw
  Linux VTs (sextant/braille glyphs aren't in the `tty1` console font), richer
  modes (quadrant/sextant/braille) on full terminal emulators.
- `preview_cache: HashMap<path, image::DynamicImage>` stays; rebuilt to a
  `Bitmap` on display.
- Info bar + help = styled `RichTextView` / dim `RichTextView`.

### 4.5 Animations — `anim` overlay (`src/fx.rs`, new per crate)

An `Fx` struct held in the reactive scope, sampling the runtime `Clock` and
requesting frames via `FrameRequester` **only while something is animating**
(zero CPU at idle). All disabled when `DOTS_NO_ANIM` is set.

- **Screen slide/fade (installer):** on `Screen` change, `Transition` eases the
  centered panel's offset + opacity (~180 ms, `EaseOut`).
- **Progress gauge (installer):** `Transition` retargets to the new ratio →
  eased fill (no jumpy steps).
- **Spinner (installer):** `Spinner` widget on `scanning…`/`connecting…`.
- **Selection slide (both):** list highlight eases to the new index.
- **Preview crossfade (wallpaper):** on selection change, `Transition` fades
  old bitmap out / new in (~150 ms).
- **Error shake (installer):** on a validation `error`, a short `Tween` jitters
  the panel x-offset (~120 ms) — a tasteful "no" signal.
- **Done celebration (installer):** one-shot `anim::particles::Burst` on the
  Done screen.

tty1 safety: every animation degrades to a no-op or instant cut when
`use_caps` reports a degraded terminal or `DOTS_NO_ANIM` is set.

## 5. Dependencies

- **installer-tui:** drop `ratatui`, `crossterm`; add `abstracttui = "0.2"`.
- **wallpaper-tui:** drop `ratatui`, `crossterm`, `ratatui-image`; add
  `abstracttui = "0.2"`. Keep `image` (used by `preview`/`tint`/`accent`).
- Plan-time spike: confirm whether `abstracttui` gates `gfx`/`anim` behind
  Cargo features (docs imply default-on); enable explicitly if so.

## 6. Testing

- All existing non-TUI tests stay green (no logic changes there).
- `installer-tui/tests/app.rs`: **two-line edit** — swap
  `use crossterm::event::{KeyCode, KeyEvent}` →
  `use dots_installer::input::{KeyCode, KeyEvent}`. Every call site
  (`key(KeyCode::Char(c))`, `KeyEvent::from(code)`, field assignments)
  unchanged.
- **New `tests/view.rs` per crate** (in `tests/`, per the no-inline-tests
  rule): headless-pump the abstracttui `App` with a canned `App` state per
  screen, assert rendered cells contain expected substrings (title, hint,
  prompt) using the `abstracttui::testing` test terminal/VT harness. Plus an
  animation smoke test using `Clock::fixed()` to assert a `Tween` samples
  correctly across pumped frames, and a `DOTS_NO_ANIM` gate test.

## 7. Risks & mitigations

- **abstracttui 0.2.x is brand-new** (published 2026-07-26). API may have rough
  edges. Mitigation: a plan-time spike confirms `App::new`/`turn`/
  `wait_for_activity`/`quitter`, `gfx::Bitmap` construction, the `Image`
  widget's mosaic/emulator-backend props + `MosaicMode` variants, and
  `FrameRequester` usage before bulk rewrite.
- **tty1 compatibility:** the installer runs on a raw Linux VT. Mitigation:
  ASCII `[x]/[ ]` markers retained; images and animations degrade via
  `use_caps`; `DOTS_NO_ANIM` escape hatch.
- **mpsc wake latency:** draining per-turn adds up to the `wait_for_activity`
  timeout of latency to worker results. Mitigation: short timeout (≤100 ms,
  matches today's poll); acceptable.

## 8. File change summary

| Crate | File | Change |
|---|---|---|
| installer-tui | `Cargo.toml` | dep swap |
| installer-tui | `src/input.rs` | **new** — key-event shim |
| installer-tui | `src/fx.rs` | **new** — animation overlay |
| installer-tui | `src/app.rs` | `handle_key` param type → `input::KeyEvent` (logic unchanged) |
| installer-tui | `src/ui.rs` | **full rewrite** — abstracttui View projection |
| installer-tui | `src/main.rs` | **rewrite** — abstracttui runtime + custom loop + worker bridge |
| installer-tui | `src/lib.rs` | export `input`, `fx` |
| installer-tui | `tests/app.rs` | 2-line `use` swap |
| installer-tui | `tests/view.rs` | **new** — headless render + animation tests |
| wallpaper-tui | `Cargo.toml` | dep swap (drop `ratatui-image`) |
| wallpaper-tui | `src/input.rs` | **new** — key-event shim |
| wallpaper-tui | `src/fx.rs` | **new** — animation overlay |
| wallpaper-tui | `src/app.rs` | `handle_key` param type → `input::KeyEvent`; drop `picker: Picker` and `preview: Option<StatefulProtocol>` fields; keep `preview_cache: HashMap<String, DynamicImage>`; the on-screen preview becomes a `gfx::Bitmap` derived from the cached `DynamicImage` at render time (selection/apply logic preserved) |
| wallpaper-tui | `src/ui.rs` | **full rewrite** — abstracttui View + `Image` widget |
| wallpaper-tui | `src/main.rs` | **rewrite** — abstracttui runtime + custom loop + worker bridge; drop `Picker::from_query_stdio` |
| wallpaper-tui | `src/lib.rs` | export `input`, `fx` |
| wallpaper-tui | `tests/view.rs` | **new** — headless render + animation tests |

Non-TUI modules in both crates: **untouched**.