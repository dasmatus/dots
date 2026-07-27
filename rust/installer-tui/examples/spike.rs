//! abstracttui API spike — proves the migration surface compiles and renders
//! headless. Exercises: `App::new` + `mount`, `Scope::signal`, `dyn_view`
//! dynamic region, `Element`/`LayoutStyle` flexbox, `Block`, `List`,
//! `Progress`, `Spinner`, `RichTextView` (render rich text), `Image` mosaic
//! (emulator backend via `Bitmap`), `Driver` + `CaptureTerm` headless render +
//! cell readback, and the `anim` overlay (`Tween`, `Transition`, `Clock`).
//!
//! Run headless: `nix develop -c cargo run --example spike` (from
//! `rust/installer-tui/`). Prints a rendered cell + animation samples; exits 0.

use std::sync::Arc;
use std::time::Duration;

use abstracttui::anim::Clock;
use abstracttui::app::Driver;
use abstracttui::gfx::MosaicMode;
use abstracttui::render::{RichLine, RichText, Span, Style as Ink};
use abstracttui::testing::CaptureTerm;
use abstracttui::widgets::{Image, ImageAlign, ImageFit, RichTextView};

use abstracttui::prelude::*;

/// Tokyonight blue, as a plain `Rgba` — the spike avoids theme token field
/// names; the real migration maps the palette onto a `TokenSet` once at startup.
const ACCENT: Rgba = Rgba::rgb(122, 162, 247);

fn main() {
    // ---- runtime + reactive state ------------------------------------------
    let mut app = App::new(Size::new(80, 24));
    app.mount(|cx| {
        let counter = cx.signal(7i32);
        let sel = cx.signal(0usize);
        let tokens = TokenSet::default();

        // `List` needs a `Scope` for its `.element`, so build it here (where
        // `cx` lives) rather than inside `dyn_view`. Static widget, dynamic
        // selection signal.
        let list = List::new(vec!["eth0 (wired)".into(), "wlan0 (wifi)".into()])
            .selection(sel)
            .element(cx, &tokens);

        let prog = Progress::new(0.42).element(&tokens);
        let spin = Spinner::new().element(&tokens);

        let mut title = RichLine::new();
        title.push(Span::new("dots — installer", Ink::new().fg(ACCENT).bold()));
        title.push(Span::new("  press Enter", Ink::new().dim()));
        let rich = RichTextView::new(RichText::from_lines(vec![title])).element(&tokens);

        // Mosaic/emulator image backend: a 4×4 RGBA bitmap → half-block glyphs.
        // No kitty/iTerm2/sixel negotiation — this is the wallpaper-tui path.
        let bmp = Arc::new(
            Bitmap::from_pixels(4, 4, vec![ACCENT; 16]).unwrap(),
        );
        let img = Image::from_bitmap(bmp)
            .mode(MosaicMode::HalfBlock)
            .fit(ImageFit::Contain)
            .align(ImageAlign::Center, ImageAlign::Center)
            .element(&tokens);

        // Dynamic region: re-renders when `counter` changes. `Signal` is
        // `Copy`, so it moves into the `FnMut` closure by value.
        let dyn_row = dyn_view(LayoutStyle::line(1), move || {
            text(format!("count = {}", counter.get()))
        });

        Element::new()
            .style(LayoutStyle::column().gap(1).padding(Edges::all(1)))
            .child(
                Block::new()
                    .border(BorderKind::Rounded)
                    .title("network")
                    .child(rich)
                    .element(&tokens)
                    .into(),
            )
            .child(list.into())
            .child(prog.into())
            .child(spin.into())
            .child(img.into())
            .child(dyn_row)
            .build()
    })
    .expect("mount");

    // ---- headless render via Driver + CaptureTerm --------------------------
    let mut term = CaptureTerm::new(Size::new(80, 24));
    let cfg = RunConfig {
        probe: false,
        ..RunConfig::default()
    };
    let mut driver = Driver::new(&mut app, &mut term, cfg).expect("driver new");
    let turn = driver.turn(&mut app, &mut term).expect("turn");
    let cell = term.screen().cell(1, 0).map(|c| c.display().to_string());
    println!(
        "spike: turn rendered={} emitted={} idle={} ; cell(1,0) = {:?}",
        turn.rendered, turn.emitted, turn.idle, cell
    );

    // ---- animation smoke (Tween + Transition + fixed Clock) ----------------
    let mut clock = Clock::fixed();
    let tween = Tween::new(0.0f32, 1.0, Duration::from_millis(200));
    let t0 = tween.sample(Duration::ZERO);
    let t1 = tween.sample(Duration::from_millis(100));
    clock.advance(Duration::from_millis(50));

    let mut trans = Transition::new(0.0f32, Duration::from_millis(200), Easing::EaseOut);
    trans.set_target(1.0, clock.now());
    clock.advance(Duration::from_millis(120));
    let eased = trans.tick(clock.now());

    println!(
        "spike: tween 0ms={:.3} 100ms={:.3} ; transition eased@170ms={:.3}",
        t0, t1, eased
    );

    // ---- cross-thread wake bridge ------------------------------------------
    let handle = app.wake_handle();
    let quit = app.quitter();
    std::thread::spawn(move || handle.post(|| {}))
        .join()
        .expect("wake join");
    quit.quit();
    println!("spike: wake_handle + quitter OK");
}
