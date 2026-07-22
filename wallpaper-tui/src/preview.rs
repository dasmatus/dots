//! Preview rendering (chafa-free) and the wallpaper thumbnail cache.
//!
//! Alacritty has no image protocol, so previews render as colored half-block
//! cells: each terminal cell holds two image rows (▀ with `fg`=upper pixel,
//! `bg`=lower pixel), doubling vertical resolution. The thumbnail cache feeds
//! [`thumb_for`] so the TUI decodes a small PNG instead of a full-res image on
//! every cursor move.

use std::fs;
use std::path::Path;

use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};

use crate::wallpapers::list_wallpapers;

/// sha1(`"{path}:{mtime}"`) → the cached thumbnail path, mirroring the Python
/// hash key. Returns `path` unchanged when no cached thumbnail exists.
pub fn thumb_for(path: &str) -> String {
    let Ok(meta) = fs::metadata(path) else {
        return path.to_string();
    };
    let Ok(mtime) = meta.modified() else {
        return path.to_string();
    };
    let secs = mtime
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let key = sha1_hex(format!("{path}:{secs}"));
    let thumb = crate::config::preview_cache_dir().join(format!("{key}.png"));
    if thumb.exists() {
        thumb.to_string_lossy().into_owned()
    } else {
        path.to_string()
    }
}

fn sha1_hex(s: String) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(s.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// `{written, skipped}` — regenerate thumbnails only when the source's mtime
/// is newer than the cached one (or the cache is missing). Atomic (temp +
/// rename) so a failed save never leaves a partial PNG the skip-guard would
/// treat as valid forever. Unreadable images are skipped with a stderr warning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheStats {
    pub written: usize,
    pub skipped: usize,
}

pub fn cache_previews(
    folder: &str,
    recursive: bool,
    out_dir: &Path,
    size: (u32, u32),
) -> CacheStats {
    let mut stats = CacheStats {
        written: 0,
        skipped: 0,
    };
    if let Err(e) = fs::create_dir_all(out_dir) {
        eprintln!("wallpaper-tui: cache mkdir {out_dir:?}: {e}");
        return stats;
    }
    for p in list_wallpapers(folder, recursive) {
        let Ok(src_meta) = fs::metadata(&p) else {
            continue;
        };
        let Ok(src_mtime) = src_meta.modified() else {
            continue;
        };
        let secs = mtime_secs(&src_mtime);
        let key = sha1_hex(format!("{}:{secs}", p.display()));
        let thumb = out_dir.join(format!("{key}.png"));
        if let Ok(thumb_meta) = fs::metadata(&thumb) {
            if let Ok(thumb_mtime) = thumb_meta.modified() {
                if mtime_secs(&thumb_mtime) >= secs {
                    stats.skipped += 1;
                    continue;
                }
            }
        }
        match make_thumbnail(&p, &thumb, size) {
            Ok(()) => stats.written += 1,
            Err(e) => eprintln!("wallpaper-tui: cache skip {}: {e}", p.display()),
        }
    }
    stats
}

fn mtime_secs(t: &std::time::SystemTime) -> u64 {
    t.duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn make_thumbnail(src: &Path, dst: &Path, size: (u32, u32)) -> anyhow::Result<()> {
    let thumb = image::open(src)?.thumbnail(size.0, size.1);
    // Write to a sibling temp then rename, so an interrupted save can't leave a
    // partial PNG that the mtime-skip guard would treat as valid forever. Save
    // with an explicit format — the `.tmp` temp name has no recognized image
    // extension, so format inference from the path would fail.
    let tmp = dst.with_extension("png.tmp");
    thumb.save_with_format(&tmp, image::ImageFormat::Png)?;
    fs::rename(&tmp, dst)?;
    Ok(())
}

/// Decode `path` (cached thumbnail preferred) into a grid of half-block
/// [`Line`]s `cols` wide by `rows` tall. Two image rows per terminal row. Any
/// decode error → a one-line placeholder.
pub fn render_cells(path: &str, cols: u16, rows: u16) -> Vec<Line<'static>> {
    let cols = cols.max(1) as u32;
    let rows = rows.max(1) as u32;
    let resolved = thumb_for(path);
    match image::open(Path::new(&resolved)) {
        Ok(img) => {
            let rgb = img.to_rgb8();
            let resized = image::imageops::resize(
                &rgb,
                cols,
                rows * 2,
                image::imageops::FilterType::Triangle,
            );
            Ok::<_, ()>(cells_from_rgb(&resized, cols, rows))
        }
        Err(_) => Err(()),
    }
    .unwrap_or_else(|_| vec![Line::from("[preview unavailable]")])
}

fn cells_from_rgb(img: &image::RgbImage, cols: u32, rows: u32) -> Vec<Line<'static>> {
    let (img_w, img_h) = (img.width(), img.height());
    let mut lines = Vec::with_capacity(rows as usize);
    for row in 0..rows {
        let mut spans: Vec<Span> = Vec::with_capacity(cols as usize);
        let mut run_start = 0u32;
        let mut run_fg = None::<Color>;
        let mut run_bg = None::<Color>;
        let flush =
            |spans: &mut Vec<Span>, start: u32, end: u32, fg: Option<Color>, bg: Option<Color>| {
                if end > start {
                    let style = match (fg, bg) {
                        (Some(f), Some(b)) => Style::default().fg(f).bg(b),
                        (Some(f), None) => Style::default().fg(f),
                        (None, Some(b)) => Style::default().bg(b),
                        (None, None) => Style::default(),
                    };
                    spans.push(Span::styled("▀".repeat((end - start) as usize), style));
                }
            };
        for col in 0..cols {
            let upper = sample(img, img_w, img_h, col, row * 2, cols, rows * 2);
            let lower = sample(img, img_w, img_h, col, row * 2 + 1, cols, rows * 2);
            let fg = Some(Color::Rgb(upper.0, upper.1, upper.2));
            let bg = Some(Color::Rgb(lower.0, lower.1, lower.2));
            if run_fg != fg || run_bg != bg {
                flush(&mut spans, run_start, col, run_fg, run_bg);
                run_start = col;
                run_fg = fg;
                run_bg = bg;
            }
        }
        flush(&mut spans, run_start, cols, run_fg, run_bg);
        if spans.is_empty() {
            spans.push(Span::raw(""));
        }
        lines.push(Line::from(spans));
    }
    lines
}

/// Nearest-neighbour sample of the source at cell (col, row), mapping the
/// `cols`×`rows` grid back onto the image's native resolution.
fn sample(
    img: &image::RgbImage,
    img_w: u32,
    img_h: u32,
    col: u32,
    row: u32,
    cols: u32,
    rows: u32,
) -> (u8, u8, u8) {
    let x = if cols >= img_w {
        col.min(img_w - 1)
    } else {
        col * img_w / cols
    };
    let y = if rows >= img_h {
        row.min(img_h - 1)
    } else {
        row * img_h / rows
    };
    let px = img.get_pixel(x.min(img_w - 1), y.min(img_h - 1));
    (px.0[0], px.0[1], px.0[2])
}

/// Parse a ``WxH`` preview-size argument (e.g. ``"320x200"``).
pub fn parse_preview_size(s: &str) -> Option<(u32, u32)> {
    let lower = s.to_ascii_lowercase();
    let (w, h) = lower.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}
