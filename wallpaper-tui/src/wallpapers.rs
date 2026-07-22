//! Wallpaper discovery and Hyprland output enumeration.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::SystemTime;

use serde::Deserialize;

/// Image extensions recognized by the picker (case-insensitive).
pub const EXTENSIONS: &[&str] = &[".jpg", ".jpeg", ".png", ".webp", ".gif"];

/// `true` iff `path`'s extension is a recognized image extension.
fn is_image(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
        return false;
    };
    EXTENSIONS.contains(&format!(".{}", ext.to_ascii_lowercase()).as_str())
}

/// mtime of `path`, or `UNIX_EPOCH` if unreadable (sorts oldest).
fn mtime(path: &Path) -> SystemTime {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH)
}

/// List wallpapers in `folder`, newest-first (mtime, descending) — matches
/// waytrogen's default sort. Returns an empty vec when the folder is missing.
pub fn list_wallpapers(folder: &str, recursive: bool) -> Vec<PathBuf> {
    if folder.is_empty() || !Path::new(folder).is_dir() {
        return Vec::new();
    }
    let mut paths: Vec<(PathBuf, SystemTime)> = Vec::new();
    if recursive {
        for entry in walkdir::WalkDir::new(folder)
            .into_iter()
            .filter_map(|e| e.ok())
        {
            if entry.file_type().is_file() && is_image(entry.path()) {
                let p = entry.path().to_path_buf();
                paths.push((p.clone(), mtime(&p)));
            }
        }
    } else if let Ok(rd) = std::fs::read_dir(folder) {
        for entry in rd.flatten() {
            let p = entry.path();
            if p.is_file() && is_image(&p) {
                paths.push((p.clone(), mtime(&p)));
            }
        }
    }
    paths.sort_unstable_by_key(|(_, mtime)| std::cmp::Reverse(*mtime));
    paths.into_iter().map(|(p, _)| p).collect()
}

#[derive(Debug, Deserialize)]
struct Monitor {
    name: String,
}

/// Best-effort output enumeration via `hyprctl monitors -j`; `[]` when not on
/// Hyprland or hyprctl is unavailable.
pub fn detect_outputs() -> Vec<String> {
    if std::env::var("HYPRLAND_INSTANCE_SIGNATURE").is_err() {
        return Vec::new();
    }
    let Ok(out) = Command::new("hyprctl").args(["monitors", "-j"]).output() else {
        return Vec::new();
    };
    serde_json::from_slice::<Vec<Monitor>>(&out.stdout)
        .unwrap_or_default()
        .into_iter()
        .map(|m| m.name)
        .collect()
}
