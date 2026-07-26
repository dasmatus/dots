//! Preview decode + the wallpaper thumbnail cache. The half-block cell tests
//! from the Python era are gone — preview rendering is now `ratatui-image`'s
//! job (Kitty graphics / Sixel / half-blocks, chosen at startup), so we assert
//! on the decoded [`image::DynamicImage`] dimensions instead of cell colors.
//! The `cache_previews` mtime-skip + atomic-write tests port directly.

mod common;

use std::fs;

use tempfile::tempdir;
use wallpaper_tui::preview::{cache_previews, load_preview};

use common::make_image;

// ── load_preview (decode → DynamicImage) ─────────────────────────────────────

#[test]
fn load_preview_decodes_image() {
    let d = tempdir().unwrap();
    let p = d.path().join("wp.png");
    make_image(&p, (60, 120, 230), 64);
    let img = load_preview(p.to_str().unwrap()).unwrap();
    assert_eq!(img.width(), 64);
    assert_eq!(img.height(), 64);
}

#[test]
fn load_preview_missing_image_is_error() {
    assert!(load_preview("/no/such/image.png").is_err());
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
    let _ = cache_previews(folder.to_str().unwrap(), true, &out, (32, 32));
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
