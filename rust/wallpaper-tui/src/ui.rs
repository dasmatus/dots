//! abstracttui view — a pure projection of `&App` (+ `&Fx` for the preview
//! crossfade) onto a View tree. No I/O lives here; reactivity comes from
//! `dyn_view` re-reading the `Signal<App>` / `Signal<Fx>` on change. The
//! preview renders through the `Image` widget on the unicode-mosaic backend
//! (half-block glyphs) — no native image protocol — and the crossfade blends
//! the new `Bitmap` toward the pane background by the eased opacity, since the
//! `Image` widget itself paints opaque cells.

use std::sync::Arc;

use abstracttui::gfx::{Bitmap, MosaicMode};
use abstracttui::prelude::*;
use abstracttui::render::{RichLine, RichText, Span, Style as Ink};
use abstracttui::ui::UiEvent;
use abstracttui::widgets::{Image, ImageAlign, ImageFit, RichTextView};

use crate::app::App;
use crate::fx::{blend_bitmap, Fx};
use crate::input::{KeyCode, KeyEvent};

/// Tokyonight (night) palette as engine `Rgba` values — no hex arithmetic in
/// widget code (the engine's `no_color_arithmetic_in_widgets` rule).
pub mod palette {
    use abstracttui::prelude::Rgba;

    pub const BG: Rgba = Rgba::rgb(0x1a, 0x1b, 0x26);
    pub const FG: Rgba = Rgba::rgb(0xc0, 0xca, 0xf5);
    pub const CYAN: Rgba = Rgba::rgb(0x7d, 0xcf, 0xff);
    pub const MAGENTA: Rgba = Rgba::rgb(0xbb, 0x9a, 0xf7);
    pub const DIM: Rgba = Rgba::rgb(0x56, 0x5f, 0x89);
    /// Info-bar ground (a dark slate, mirroring the old `DarkGray` bar).
    pub const INFO_BG: Rgba = Rgba::rgb(0x16, 0x16, 0x20);
    /// Selection highlight background (light blue, mirroring the old
    /// `LightBlue`).
    pub const SEL_BG: Rgba = Rgba::rgb(0x7a, 0xa2, 0xf7);
}

const HELP: &str = "Enter:apply  j/k:move  m:mode  c:color  o:output  p:preview  r:restore  q:quit";

/// Root component: one `dyn_view` that re-reads `app` and `fx` and projects
/// the picker, plus a root `on_event` that bridges engine key events into the
/// pure `App` state machine and retargets the preview crossfade on selection
/// change. Reads via `with` (no `App` clone — the `preview_cache` is heavy).
#[must_use]
pub fn root_view(app: Signal<App>, fx: Signal<Fx>) -> View {
    let tokens = TokenSet::default();
    Element::new()
        .style(LayoutStyle::fill())
        .child(dyn_view(LayoutStyle::fill(), move || {
            app.with(|a| fx.with(|f| main_view(a, f, &tokens)))
        }))
        .on_event(move |_, ev| {
            let UiEvent::Key(k) = ev else {
                return;
            };
            let Some(code) = map_key(k.key) else {
                return;
            };
            // Retarget the crossfade when the selection moves. `handle_key`
            // already calls `request_preview` for cursor moves, so the worker
            // dispatch is in lockstep with the fade.
            let prev = app.with_untracked(|a| a.selected);
            app.update(|a| a.handle_key(KeyEvent::from(code)));
            if app.with_untracked(|a| a.selected) != prev {
                fx.update(Fx::retarget_crossfade);
            }
        })
        .build()
}

/// Map the engine's `Key` to the picker's `input::KeyCode`. Unknown keys map
/// to `None` — the picker ignores them.
fn map_key(k: Key) -> Option<KeyCode> {
    Some(match k {
        Key::Char(c) => KeyCode::Char(c),
        Key::Enter => KeyCode::Enter,
        Key::Escape => KeyCode::Esc,
        Key::Backspace => KeyCode::Backspace,
        Key::Up => KeyCode::Up,
        Key::Down => KeyCode::Down,
        _ => return None,
    })
}

/// The picker: a horizontal split (list | preview) above an info bar above a
/// one-line help footer. The empty state replaces the body with the "no
/// wallpapers" message.
fn main_view(a: &App, f: &Fx, tokens: &TokenSet) -> View {
    if a.wallpapers.is_empty() {
        return empty_view(a, tokens);
    }
    Element::new()
        .style(
            LayoutStyle::column()
                .width(Dimension::Percent(1.0))
                .height(Dimension::Percent(1.0)),
        )
        .child(body_row(a, f, tokens))
        .child(info_view(a, tokens))
        .child(help_view(tokens))
        .build()
}

/// `list | preview` — the list grows, the preview is a fixed 50-cell pane
/// (mirroring the old `Length(50)`).
fn body_row(a: &App, f: &Fx, tokens: &TokenSet) -> View {
    let list = Element::new()
        .style(
            LayoutStyle::default()
                .grow(1.0)
                .height(Dimension::Percent(1.0)),
        )
        .child(list_view(a, tokens))
        .build();
    let preview = Element::new()
        .style(LayoutStyle::default().w(50).height(Dimension::Percent(1.0)))
        .child(preview_view(a, f, tokens))
        .build();
    Element::new()
        .style(LayoutStyle::row().width(Dimension::Percent(1.0)).grow(1.0))
        .child(list)
        .child(preview)
        .build()
}

/// The wallpaper list — a bordered block titled "wallpapers" with one
/// `RichLine` per entry. The selected entry is prefixed with `> ` and drawn
/// black-on-light-blue bold (the old highlight style).
fn list_view(a: &App, tokens: &TokenSet) -> View {
    let lines: Vec<RichLine> = a
        .wallpapers
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let name = p.file_name().map_or_else(
                || p.to_string_lossy().into_owned(),
                |n| n.to_string_lossy().into_owned(),
            );
            if i == a.selected {
                span_line(
                    format!("> {name}"),
                    Ink::new().fg(palette::BG).bg(palette::SEL_BG).bold(),
                )
            } else {
                span_line(format!("  {name}"), Ink::new().fg(palette::FG))
            }
        })
        .collect();
    Block::new()
        .border(BorderKind::Plain)
        .title("wallpapers")
        .layout(LayoutStyle::fill())
        .child(RichTextView::new(RichText::from_lines(lines)).element(tokens))
        .element(tokens)
        .into()
}

/// The preview pane — a bordered block titled "preview" holding either the
/// mosaic `Image` (with the crossfade blend applied), a `rendering…` /
/// `[preview unavailable]` label, or a blank pane when the preview is hidden.
fn preview_view(a: &App, f: &Fx, tokens: &TokenSet) -> View {
    let inner: View = if a.show_preview {
        if let Some(bmp) = &a.preview {
            let opacity = f.crossfade_opacity();
            // Blend toward the pane ground while the fade is in flight; at
            // full opacity (or with animations off) show the raw bitmap.
            let displayed: Arc<Bitmap> =
                if (opacity - 1.0).abs() < 1e-3 || !crate::fx::animations_enabled() {
                    bmp.clone()
                } else {
                    Arc::new(blend_bitmap(bmp, palette::BG, opacity))
                };
            Image::from_bitmap(displayed)
                .fit(ImageFit::Contain)
                .align(ImageAlign::Center, ImageAlign::Center)
                .mode(MosaicMode::HalfBlock)
                .element(tokens)
                .into()
        } else {
            let label = if a.preview_pending.is_some() {
                "rendering…"
            } else {
                "[preview unavailable]"
            };
            RichTextView::new(RichText::plain(label, Ink::new().fg(palette::DIM)))
                .element(tokens)
                .into()
        }
    } else {
        Element::new().style(LayoutStyle::fill()).build()
    };
    Block::new()
        .border(BorderKind::Plain)
        .title("preview")
        .layout(LayoutStyle::fill())
        .child(inner)
        .element(tokens)
        .into()
}

/// One-line info bar — `App::info_text` on a dark-slate ground, bold light
/// text (the old `DarkGray` + white bold).
fn info_view(a: &App, tokens: &TokenSet) -> View {
    Block::new()
        .border(BorderKind::None)
        .fill(palette::INFO_BG)
        .layout(LayoutStyle::line(1).width(Dimension::Percent(1.0)))
        .child(
            RichTextView::new(RichText::plain(
                &a.info_text(),
                Ink::new().fg(palette::FG).bold(),
            ))
            .element(tokens),
        )
        .element(tokens)
        .into()
}

/// One-line dim help footer.
fn help_view(tokens: &TokenSet) -> View {
    Block::new()
        .border(BorderKind::None)
        .layout(LayoutStyle::line(1).width(Dimension::Percent(1.0)))
        .child(
            RichTextView::new(RichText::plain(HELP, Ink::new().fg(palette::DIM))).element(tokens),
        )
        .element(tokens)
        .into()
}

/// Empty state: the "no wallpapers found in: <folder>" message fills the body,
/// with the info + help bars beneath.
fn empty_view(a: &App, tokens: &TokenSet) -> View {
    let folder = if a.config.wallpaper_folder.is_empty() {
        "?"
    } else {
        &a.config.wallpaper_folder
    };
    let msg = span_line(
        format!("No wallpapers found in: {folder}"),
        Ink::new().fg(palette::CYAN),
    );
    Element::new()
        .style(
            LayoutStyle::column()
                .width(Dimension::Percent(1.0))
                .height(Dimension::Percent(1.0)),
        )
        .child(
            Element::new()
                .style(
                    LayoutStyle::default()
                        .width(Dimension::Percent(1.0))
                        .grow(1.0),
                )
                .child(
                    Block::new()
                        .layout(LayoutStyle::fill())
                        .child(RichTextView::new(RichText::from_lines(vec![msg])).element(tokens))
                        .element(tokens)
                        .into(),
                )
                .build(),
        )
        .child(info_view(a, tokens))
        .child(help_view(tokens))
        .build()
}

/// A single-span `RichLine` with the given ink.
fn span_line(text: impl Into<String>, ink: Ink) -> RichLine {
    RichLine::from_spans(vec![Span::new(text, ink)])
}
