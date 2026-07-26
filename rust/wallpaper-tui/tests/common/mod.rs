//! Shared fixtures for the integration tests, ported from the pytest
//! ``conftest.py``. Every I/O test redirects into a [`tempfile::TempDir`] so
//! nothing touches the real ``~/.config`` or the Nix store, and no test mutates
//! process-global env (which would race under parallel ``cargo test``).
//
// Each test binary only uses a subset of these helpers, so the rest would trip
// `dead_code` warnings (fatal under the repo's `-D warnings` lint gate).
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use image::{ImageBuffer, Rgb, RgbImage};
use wallpaper_tui::tint::TintCtx;

/// Write a flat-color PNG of `size`×`size` — the Rust `image` equivalent of
/// ``PIL.Image.new("RGB", (size, size), rgb)``.
pub fn make_image(path: &Path, rgb: (u8, u8, u8), size: u32) {
    let img: RgbImage = ImageBuffer::from_pixel(size, size, Rgb([rgb.0, rgb.1, rgb.2]));
    img.save(path).unwrap();
}

/// A flat-color PNG with a small differently-colored patch in the top-left —
/// ports the ``mostly_blue`` extractor fixture (dominant vibrant wins).
pub fn make_image_with_patch(path: &Path, base: (u8, u8, u8), patch: (u8, u8, u8)) {
    let mut img: RgbImage = ImageBuffer::from_pixel(64, 64, Rgb([base.0, base.1, base.2]));
    for x in 0..8 {
        for y in 0..8 {
            img.put_pixel(x, y, Rgb([patch.0, patch.1, patch.2]));
        }
    }
    img.save(path).unwrap();
}

/// A minimal Kvantum theme tree mirroring catppuccin-frappe-blue's shape.
pub fn make_kvantum_base(root: &Path) -> PathBuf {
    let theme = root.join("catppuccin-frappe-blue");
    std::fs::create_dir_all(&theme).unwrap();
    std::fs::write(
        theme.join("catppuccin-frappe-blue.kvconfig"),
        "[%General]\ncomment=Catppuccin-Frappe-Blue\n\
         [GeneralColors]\nhighlight.color=#8CAAEE4D\nlink.color=#8CAAEE\n\
         link.visited.color=#98B2EF\nwindow.color=#303446\ntext.color=#C6D0F5\n",
    )
    .unwrap();
    std::fs::write(
        theme.join("catppuccin-frappe-blue.svg"),
        "<svg><rect fill=\"#8CAAEE\"/><rect fill=\"#839EDD\"/><rect fill=\"#303446\"/></svg>\n",
    )
    .unwrap();
    theme
}

/// A minimal MoreWaita-shaped icon theme tree with the Adwaita-blue family.
pub fn make_icon_base(root: &Path) -> PathBuf {
    let theme = root.join("MoreWaita");
    std::fs::create_dir_all(theme.join("scalable").join("places")).unwrap();
    std::fs::write(
        theme.join("index.theme"),
        "[Icon Theme]\nName=MoreWaita\nInherits=Adwaita,AdwaitaLegacy,hicolor\nExample=pamac\n",
    )
    .unwrap();
    std::fs::write(
        theme.join("scalable").join("places").join("folder.svg"),
        "<svg><stop stop-color=\"#62a0ea\"/><stop stop-color=\"#afd4ff\"/><rect fill=\"#438de6\"/></svg>\n",
    )
    .unwrap();
    std::fs::write(
        theme
            .join("scalable")
            .join("places")
            .join("folder-ruby.svg"),
        "<svg><rect fill=\"#438de6\"/><rect fill=\"#000000\"/></svg>\n",
    )
    .unwrap();
    theme
}

/// A synthetic rofi base rasi matching the tokyonight theme's accent/selected-bg.
const ROFI_BASE: &str =
    "* {\n  accent:      #7aa2f7;\n  selected-bg: #2d3252;\n  bg: #1a1b26;\n}\n";

/// Build a [`TintCtx`] whose every path points inside `tmp`, with no Hyprland
/// signature and icon-selection disabled (gsettings absent). Mirrors the
/// pytest ``isolated_paths`` fixture: the rofi base is a synthetic rasi, the
/// kvantum/icon bases are `None` unless `with_bases` provides them.
pub fn tint_ctx(tmp: &Path, kvantum_base: Option<PathBuf>, icon_base: Option<PathBuf>) -> TintCtx {
    let tint_dir = tmp.join("tint");
    let rofi_base = tmp.join("rofi").join("tokyonight.rasi");
    std::fs::create_dir_all(rofi_base.parent().unwrap()).unwrap();
    std::fs::write(&rofi_base, ROFI_BASE).unwrap();
    TintCtx {
        kvantum_base,
        icon_base,
        kvantum_dest: tmp.join("Kvantum").join("WallpaperTint"),
        kvantum_select: tmp.join("Kvantum").join("kvantum.kvconfig"),
        icon_dest: tmp.join("icons").join("MoreWaita-Tint"),
        tint_dir,
        rofi_base,
        his: None,
        try_icon_select: false,
    }
}

/// A flat green wallpaper under `tmp`, the apply_tint fixture input.
pub fn wallpaper(tmp: &Path) -> PathBuf {
    let p = tmp.join("wp.png");
    make_image(&p, (40, 200, 60), 64);
    p
}
