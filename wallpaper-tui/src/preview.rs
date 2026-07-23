//! The wallpaper thumbnail cache and the preview decode into an
//! [`image::DynamicImage`] consumed by `ratatui-image`'s protocol state.
//!
//! The TUI renders previews with the terminal's native image protocol (Kitty
//! graphics on Kitty/Ghostty, falling back to Sixel/iTerm2/half-blocks
//! elsewhere — chosen by `ratatui_image::picker::Picker` at startup). The
//! thumbnail cache feeds [`thumb_for`] so the worker decodes a small PNG rather
//! than the full-res wallpaper on every cursor move; the decoded
//! `DynamicImage` is sent to the UI thread, which builds a
//! `ratatui_image::protocol::StatefulProtocol` sized to the preview pane at
//! render time.

use std::fs;
use std::path::Path;

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

/// Decode `path` (cached thumbnail preferred) into a [`image::DynamicImage`]
/// for `ratatui-image` to render with the terminal's native image protocol.
/// Propagates the decode error so the worker can signal a failed preview.
pub fn load_preview(path: &str) -> anyhow::Result<image::DynamicImage> {
    let resolved = thumb_for(path);
    Ok(image::open(Path::new(&resolved))?)
}

/// Parse a ``WxH`` preview-size argument (e.g. ``"320x200"``).
pub fn parse_preview_size(s: &str) -> Option<(u32, u32)> {
    let lower = s.to_ascii_lowercase();
    let (w, h) = lower.split_once('x')?;
    Some((w.parse().ok()?, h.parse().ok()?))
}
