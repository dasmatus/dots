# abstracttui 0.2.24 — API reference (migration spike)

Confirmed by reading the cached crate source at
`~/.cargo/registry/src/index.crates.io-…/abstracttui-0.2.24/` (ground truth,
not docs.rs summaries). Every signature below was verified present + public.

`use abstracttui::prelude::*;` re-exports the symbols used here. Paths are
given for lookup only — prefer the prelude.

## 1. Runtime / app

```rust
// src/app/mod.rs
pub struct App { … }
impl App {
    pub fn new(viewport: Size) -> App;
    pub fn simple(component: impl FnOnce(Scope) -> View) -> Result<()>; // mount+run
    pub fn mount(&mut self, component: impl FnOnce(Scope) -> View) -> Result<()>;
    pub fn pump(&mut self) -> PumpReport;          // headless one-shot: drains jobs, renders once
    pub fn wake_handle(&self) -> WakeHandle;       // cross-thread bridge
    pub fn quitter(&self) -> Quitter;              // Quitter::quit(&self) flips the run-loop flag
    pub fn run(mut self) -> Result<()>;            // blocking high-level run (real terminal)
}
pub struct PumpReport { pub posted_jobs: usize, pub frame_requested: bool }

// src/reactive/scheduler.rs
pub struct WakeHandle { … }      // Send + Clone
impl WakeHandle {
    pub fn post(&self, f: impl FnOnce() + Send + 'static);  // worker threads call this
}
pub fn request_frame();          // ask for another turn (idle animations)

// src/app/driver.rs  — manual loop (what main.rs uses)
pub struct Driver { … }
impl Driver {
    pub fn new(app: &mut App, term: &mut dyn Terminal, cfg: RunConfig) -> Result<Driver>;
    pub fn turn(&mut self, app: &mut App, term: &mut dyn Terminal) -> Result<Turn>;
    pub fn wait_for_activity(&mut self, term: &mut dyn Terminal) -> Result<()>; // blocks for input/frame
}
pub struct RunConfig { pub caps: Option<Capabilities>, pub enter: Option<EnterOptions>, pub probe: bool }
impl Default for RunConfig;   // RunConfig { probe: false, ..RunConfig::default() } for headless
#[derive(Default, …)]
pub struct Turn { pub events: usize, pub rendered: bool, pub emitted: bool, pub quit: bool, pub idle: bool }

// src/app/mod.rs
pub struct Quitter(Rc<Cell<bool>>); impl Quitter { pub fn quit(&self); }
```

**Bridge pattern for our crates:** keep the pure `App` state machine; hold it
in `cx.signal(app)`. Worker threads call `handle.post(move || app_sig.update(|a| a.on_install_event(ev)))`.
A root `dyn_view` reads `app_sig.get()` and rebuilds the View tree. Key events:
register a root key handler → map to `input::KeyEvent` → `app_sig.update(|a| a.handle_key(k))`.

## 2. Reactive core

```rust
// src/reactive/scope.rs
#[derive(Copy, Clone)] pub struct Scope { … }   // Copy: cx survives cx.signal(..)
impl Scope {
    pub fn signal<T: 'static>(self, value: T) -> Signal<T>;
    pub fn memo<T, F>(self, f: F) -> Memo<T>;
    pub fn effect(self, f: impl FnMut() + 'static) -> Effect;
}

// src/reactive/signal.rs
pub struct Signal<T> { … }   // Copy + Send (arena index)
impl<T> Signal<T> {
    pub fn get(self) -> T;            // clones out for non-Copy T — prefer update() for big state
    pub fn set(self, value: T);
    pub fn update(self, f: impl FnOnce(&mut T));   // in-place mutate, no clone
}

// src/ui/view.rs
pub fn dyn_view(style: Style, build: impl FnMut() -> View + 'static) -> View;
//   closure takes NO cx; capture Signal handles and read via .get().
//   re-runs whenever a captured signal changes (fine-grained).
```

## 3. View tree

```rust
// src/ui/view.rs
pub struct Element { … }            // generic container
impl Element {
    pub fn new() -> Element;
    pub fn style(self, style: Style) -> Element;     // Style here = layout::Style (= LayoutStyle)
    pub fn child(self, view: View) -> Element;
    pub fn children(self, views: impl IntoIterator<Item = View>) -> Element;
    pub fn build(self) -> View;
}
pub fn text(content: impl Into<String>) -> View;     // bare text leaf
```

`mount(|cx| Element::new().style(LayoutStyle::column()).child(…).build())`.

## 4. Layout (`LayoutStyle` = `layout::Style`)

```rust
// src/layout/mod.rs
pub type LayoutStyle = Style;       // re-exported; LayoutStyle == layout::Style

// src/layout/style.rs
pub enum Dimension { Auto, Cells(i32), Percent(f32) }  // Percent is 0.0..=1.0 (fraction, not 0–100)
pub struct Edges { pub left,right,top,bottom: i32 }
impl Edges { pub const ZERO: Edges; pub const fn all(n: i32) -> Edges; pub const fn hv(h: i32, v: i32) -> Edges; }
pub struct Inset { pub left,right,top,bottom: Option<i32> }   // absolute positioning
pub enum Justify { … }   pub enum Align { … }                 // main/cross axis

impl Style {                       // builder chain
    pub fn column() -> Style;      // stack children vertically (default is row)
    pub fn row() -> Style;
    pub fn fill() -> Style;        // grow both axes
    pub fn line(rows: i32) -> Style; // full-width n-row slot
    pub fn gap(self, g: i32) -> Style;
    pub fn padding(self, p: Edges) -> Style;
    pub fn margin(self, p: Edges) -> Style;
    pub fn w(self, cells: i32) -> Style;   pub fn h(self, cells: i32) -> Style;
    pub fn min_w(self, cells: i32) -> Style; pub fn min_h(self, cells: i32) -> Style;
    pub fn grow(self, g: f32) -> Style;
    // …absolute(Inset), grid(…), wrap(bool), justify/align setters
}
```

## 5. Widgets

All widget builders terminate in either `.view(cx: Scope) -> View` (theme from
context) or `.element(&TokenSet) -> Element` (explicit tokens). Inside `dyn_view`
(no `cx`), capture a `TokenSet` and use `.element(&tokens)`.

```rust
// src/widgets/block.rs
pub enum BorderKind { Plain, Rounded, Double, Heavy, None }
pub enum TitleAlign { Left, Center, Right }
pub struct Block { … }
impl Block {
    pub fn new() -> Block;
    pub fn border(self, kind: BorderKind) -> Block;
    pub fn title(self, t: impl Into<String>) -> Block;
    pub fn title_align(self, a: TitleAlign) -> Block;
    pub fn focused(self, b: bool) -> Block;
    pub fn fill(self, ground: Rgba) -> Block;
    pub fn shadow(self, ground: Rgba) -> Block;
    pub fn layout(self, style: LayoutStyle) -> Block;
    pub fn child(self, view: impl Into<View>) -> Block;
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, t: &TokenSet) -> Element;
}

// src/widgets/list.rs
pub struct List { … }
impl List {
    pub fn new(items: Vec<String>) -> List;
    pub fn selection(self, sel: Signal<usize>) -> List;     // reactive highlight
    pub fn selection_key(self, key: Signal<String>) -> List;
    pub fn key_fn(self, f: impl Fn(usize, &str) -> String + 'static) -> List;
    pub fn on_select(self, f: impl FnMut(usize) + 'static) -> List;  // selection-changed callback
    pub fn focus_signal(self, focused: Signal<bool>) -> List;
    pub fn scroll_to(self, request: Signal<Option<usize>>) -> List;
    pub fn layout(self, style: LayoutStyle) -> List;
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, cx: Scope, t: &TokenSet) -> Element;
}

// src/widgets/progress.rs
pub struct Progress { … }
impl Progress {
    pub fn new(fraction: f32) -> Progress;   // 0.0..=1.0, sub-cell precision
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, t: &TokenSet) -> Element;
}

// src/widgets/spinner.rs
pub struct Spinner { … }
impl Spinner {
    pub fn new() -> Spinner;
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, t: &TokenSet) -> Element;
}

// src/widgets/richtext.rs   (the widget is `richtext.rs`, not `rich_text.rs`)
pub struct RichTextView { … }
impl RichTextView {
    pub fn new(text: RichText) -> RichTextView;
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, t: &TokenSet) -> Element;
}

// src/widgets/image.rs   — MOSAIC/EMULATOR backend by default
pub enum MosaicMode { HalfBlock, Quadrant, Sextant, Braille }
pub enum ImageFit { … }      pub enum ImageAlign { Start, Center, End }
pub struct Image { … }
impl Image {
    pub fn from_bitmap(bitmap: Arc<Bitmap>) -> Image;   // decoded RGBA -> mosaic glyphs
    pub fn from_path(path: impl AsRef<Path>) -> Image;
    pub fn fit(self, fit: ImageFit) -> Image;
    pub fn mode(self, mode: MosaicMode) -> Image;        // force HalfBlock on tty1
    pub fn align(self, h: ImageAlign, v: ImageAlign) -> Image;
    pub fn view(self, cx: Scope) -> View;
    pub fn element(self, t: &TokenSet) -> Element;
}
```

`Image` **always** renders unicode mosaic cells (half-block/quadrant/sextant/
braille). Native image protocols live at the presenter layer, not the widget —
so "emulator backend" is the default; no `choose_channel`/protocol negotiation
needed. `use_caps(cx)` reports terminal `Capabilities` so we can pick the safest
`MosaicMode` (half-blocks on raw `tty1`; richer on full emulators).

## 6. Rich text (`render`)

```rust
// src/render/style.rs
pub struct Style { … }          // the INK style (fg/bg/attrs) — distinct from layout::Style
impl Style {
    pub fn new() -> Style;
    pub fn fg(self, c: Rgba) -> Style;  pub fn bg(self, c: Rgba) -> Style;
    pub fn bold(self) -> Style;  pub fn dim(self) -> Style;
    pub fn italic(self) -> Style; pub fn underline(self) -> Style;
}

// src/render/rich.rs
pub struct Span { pub text: String, pub style: Style, pub link: Option<String> }
impl Span { pub fn new(text: impl Into<String>, style: Style) -> Span; }
pub struct RichLine { pub spans: Vec<Span> }
impl RichLine {
    pub fn new() -> RichLine;
    pub fn from_spans(spans: Vec<Span>) -> RichLine;
    pub fn push(&mut self, span: Span);     // coalesces adjacent same-ink spans
}
pub struct RichText { … }
impl RichText {
    pub fn new() -> RichText;
    pub fn from_lines(lines: Vec<RichLine>) -> RichText;
    pub fn plain(s: &str, style: Style) -> RichText;
    pub fn height(&self) -> i32;  pub fn width(&self) -> i32;
    pub fn wrap(&self, max_width: i32) -> RichText;
}
```

To build a prompt: `RichText::from_lines(vec![ { let mut l = RichLine::new(); l.push(Span::new("name: ", Style::new().fg(tokens.accent))); l } ])`.

## 7. Graphics — `Bitmap`

```rust
// src/gfx/bitmap.rs
pub struct Bitmap { … }
impl Bitmap {
    pub fn new(w: u32, h: u32, fill: Rgba) -> Bitmap;
    pub fn from_pixels(w: u32, h: u32, px: Vec<Rgba>) -> Option<Bitmap>;  // px.len() == w*h
    pub fn width(&self) -> u32;  pub fn height(&self) -> u32;
    pub fn is_empty(&self) -> bool;
}
```
Wallpaper bridge: worker decodes via existing `preview::load_preview` (returns
`image::DynamicImage`) → `img.to_rgba8()` → collect `Vec<Rgba>` →
`Bitmap::from_pixels` → `Arc::new(bitmap)` → `Image::from_bitmap`. Cache the
`DynamicImage` (`preview_cache`); rebuild the `Bitmap` on display.

## 8. Color, geometry, theme

```rust
// src/base/color.rs
pub struct Rgba { … }
impl Rgba {
    pub const fn new(r: u8, g: u8, b: u8, a: u8) -> Self;
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self;       // opaque
    pub const TRANSPARENT: Rgba; pub const BLACK: Rgba; pub const WHITE: Rgba;
    pub const fn with_alpha(self, a: u8) -> Self;
    pub fn from_hex(s: &str) -> Option<Rgba>;
}

// src/base/geom.rs
pub struct Point { pub x: i32, pub y: i32 }   // Point::new(x, y)
pub struct Size  { pub w: i32, pub h: i32 }   // Size::new(w, h); is_empty, area

// src/theme/tokens.rs + registry.rs
pub struct TokenSet { … }     // impl Default -> abstract-dark house palette
impl Default for TokenSet;   // TokenSet::default()  OR  default_theme().tokens
pub enum TokenId { Bg, Surface, SurfaceRaised, Overlay, Border, BorderFocus,
    Text, TextMuted, TextFaint, Accent, AccentAlt, Ok, Warn, Error, Info,
    SelectionBg, SelectionFg, Cursor, Link, Shadow, ShadowGround,
    Chart0..Chart5, … }
pub fn default_theme() -> &'static Theme;   // theme::registry
// Tokyonight palette from ui.rs maps onto these tokens (Accent=blue, Error=red, …).
```

## 9. Animations (`anim`)

```rust
// src/anim/mod.rs
pub struct Clock { … }
impl Clock {
    pub fn real() -> Clock;            // wall clock
    pub fn fixed() -> Clock;           // virtual, starts at zero
    pub fn now(&self) -> Duration;
    pub fn advance(&mut self, by: Duration);   // panic on real clock — use fixed() in tests
}

// src/anim/easing.rs
pub enum Easing { Linear, EaseIn, EaseOut, EaseInOut,
    CubicBezier(f32,f32,f32,f32), Bounce, Elastic(f32), Spring(f32) }

// src/anim/tween.rs   — one-shot A→B
pub struct Tween<T: Lerp> { … }
impl<T: Lerp> Tween<T> {
    pub fn new(from: T, to: T, duration: Duration) -> Tween<T>;   // Linear
    pub fn sample(&self, elapsed: Duration) -> T;                  // pure; no clock
}

// src/anim/transition.rs  — retargetable, live
pub struct Transition<T: Lerp> { … }
impl<T: Lerp> Transition<T> {
    pub fn new(initial: T, duration: Duration, easing: Easing) -> Transition<T>;
    pub fn value(&self) -> T;
    pub fn target(&self) -> T;
    pub fn set_target(&mut self, target: T, now: Duration) -> &mut Self;  // retarget mid-flight
    pub fn tick(&mut self, now: Duration) -> T;                          // advance + sample
}

// src/anim/particles.rs
pub struct ParticleField { … }   // Burst on Done screen; ParticleField::new(seed)
```

`DOTS_NO_ANIM` gate: when set, skip `anim` overlay entirely (instant cuts).
`FrameRequester`: call `abstracttui::reactive::request_frame()` while an
animation is in flight so the loop re-renders; zero CPU at idle.

## 10. Capabilities + testing

```rust
// src/app/caps.rs
pub fn use_caps(_cx: Scope) -> Signal<Capabilities>;   // reactive terminal caps
pub fn current_caps() -> Capabilities;                 // one-shot

// src/testing/capture.rs  — headless Terminal
pub struct CaptureTerm { … }   // impl Terminal
impl CaptureTerm {
    pub fn new(size: Size) -> CaptureTerm;
    pub fn screen(&self) -> &VtScreen;     // read back rendered cells
}
// src/testing/vt.rs
impl VtScreen {
    pub fn size(&self) -> Size;
    pub fn cell(&self, x: i32, y: i32) -> Option<&VtCell>;
}
// src/testing/grid.rs
pub struct VtCell { pub content: CellContent, pub paint: Paint }
impl VtCell { pub fn display(&self) -> &str;  pub fn ch(&self) -> char; }

// src/term/mod.rs — the Terminal trait CaptureTerm implements
pub trait Terminal {
    fn size(&mut self) -> Result<Size>;
    fn read(&mut self, deadline: Option<Instant>) -> Result<TermRead<'_>>;
    fn write(&mut self, bytes: &[u8]) -> Result<()>;
    fn flush(&mut self) -> Result<()>;
}
```

Headless test recipe:
```rust
let mut app = App::new(Size::new(80, 24));
let app_sig /* … */;
app.mount(|cx| build_view(cx, &app_sig)).unwrap();
let _ = app.pump();                       // renders once into the internal buffer
let mut term = CaptureTerm::new(Size::new(80, 24));
// OR use Driver::new + turn to render into CaptureTerm and read term.screen().
```
For view tests: render each `Screen` and assert `term.screen().cell(x,y).map(|c| c.display())` contains the title/hint/prompt.

## 11. Migration notes (what this confirms)

- `App::pump()` exists for headless one-shots — but it renders into the app's
  internal buffer, not a `CaptureTerm`. For tests that read cells, use
  `Driver::new(&mut app, &mut term, RunConfig{probe:false,..Default::default()})`
  + `driver.turn(&mut app, &mut term)` so output lands in `term.screen()`.
- `Scope: Copy` ⇒ `let s = cx.signal(v); … .view(cx)` compiles (cx not moved).
- `Signal: Copy + Send` ⇒ moves into `dyn_view` closures and `WakeHandle::post`
  closures freely.
- The worker bridge is `wake_handle().post(move || sig.update(|a| …))`, NOT raw
  `mpsc` polling. Keep `mpsc` only if a worker must stream many events cheaply;
  otherwise one `post` per event.
- `Image::from_bitmap(Arc<Bitmap>)` is the mosaic/emulator path — no
  `Picker`, no `StatefulProtocol`, no `from_query_stdio` DCS query. This is the
  wallpaper-tui simplification.
- `TokenSet::default()` (abstract-dark) is the no-theme-context way to build
  widgets inside `dyn_view`. The Tokyonight palette becomes a custom `TokenSet`
  built once at startup (per the engine's `no_color_arithmetic_in_widgets` rule).