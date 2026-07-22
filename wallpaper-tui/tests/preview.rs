//! Half-block preview rendering and the wallpaper thumbnail cache. Ports
//! ``test_preview.py`` — the chafa ANSI-parser tests are replaced by
//! [`render_cells`] tests (chafa was dropped in the Rust rewrite); the
//! ``cache_previews`` mtime-skip + atomic-write tests port directly.

mod common;

use std::fs;

use ratatui::style::Color;
use tempfile::tempdir;
use wallpaper_tui::preview::{cache_previews, render_cells};

use common::make_image;

// ── render_cells (half-block preview) ────────────────────────────────────────

#[test]
fn render_cells_two_color_image_makes_half_blocks() {
    // A 1×2 image (top red, bottom blue) at cols=1, rows=1 → one Line with one
    // ▀ Span whose fg=red (upper pixel) and bg=blue (lower pixel).
    let d = tempdir().unwrap();
    let p = d.path().join("two.png");
    {
        let mut img: image::RgbImage = image::ImageBuffer::from_pixel(1, 2, image::Rgb([0, 0, 0]));
        img.put_pixel(0, 0, image::Rgb([255, 0, 0])); // upper
        img.put_pixel(0, 1, image::Rgb([0, 0, 255])); // lower
        img.save(&p).unwrap();
    }
    let lines = render_cells(p.to_str().unwrap(), 1, 1);
    assert_eq!(lines.len(), 1);
    let line = &lines[0];
    assert_eq!(line.spans.len(), 1);
    let span = &line.spans[0];
    assert_eq!(span.content, "▀");
    let style = span.style;
    // fg = upper pixel (red), bg = lower pixel (blue).
    assert_eq!(style.fg, Some(Color::Rgb(255, 0, 0)));
    assert_eq!(style.bg, Some(Color::Rgb(0, 0, 255)));
}

#[test]
fn render_cells_missing_image_is_placeholder() {
    let lines = render_cells("/no/such/image.png", 4, 2);
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0].spans[0].content, "[preview unavailable]");
}

// ── cache_previews ───────────────────────────────────────────────────────────

#[test]
fn cache_previews_writes_thumbnails() {
    let d = tempdir().unwrap();
    let folder = d.path().join("walls");
    fs::create_dir_all(&folder).unwrap();
    make_image(&folder.join("a.png"), (10, 20, 30), 64);
    make_image(&folder.join("b.png"), (40, 50, 60), 64);
    let out = d.path().join("thumbs");
    let stats = cache_previews(folder.to_str().unwrap(), true, &out, (32, 32));
    assert_eq!(stats.written, 2);
    let pngs: Vec<_> = std::fs::read_dir(&out)
        .unwrap()
        .filter_map(|e| e.ok())
        .collect();
    assert_eq!(pngs.len(), 2);
}

#[test]
fn cache_previews_skips_unchanged() {
    let d = tempdir().unwrap();
    let folder = d.path().join("walls");
    fs::create_dir_all(&folder).unwrap();
    make_image(&folder.join("a.png"), (10, 20, 30), 64);
    let out = d.path().join("thumbs");
    cache_previews(folder.to_str().unwrap(), true, &out, (32, 32));
    // Second run: same mtime -> skip.
    let stats = cache_previews(folder.to_str().unwrap(), true, &out, (32, 32));
    assert_eq!(stats.written, 0);
    assert_eq!(stats.skipped, 1);
}

#[test]
fn cache_previews_nonexistent_folder() {
    let d = tempdir().unwrap();
    let stats = cache_previews(
        d.path().join("nope").to_str().unwrap(),
        true,
        &d.path().join("thumbs"),
        (32, 32),
    );
    assert_eq!(stats.written, 0);
}
