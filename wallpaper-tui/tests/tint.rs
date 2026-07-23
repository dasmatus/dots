//! Per-target tint writers and the apply_tint orchestrator. Writers are pure
//! (string in → string out); tree tinters and the orchestrator use the
//! [`common::tint_ctx`] fixture + synthetic base themes so nothing touches the
//! real ``~/.config`` or the Nix store. Ports ``test_tint_writers.py``.

mod common;

use std::fs;
use std::path::Path;

use tempfile::tempdir;
use wallpaper_tui::accent::TintBackend;
use wallpaper_tui::accent::{hex_to_hls, hls_to_hex};
use wallpaper_tui::config::TintState;
use wallpaper_tui::tint::{
    apply_tint_ctx, gtk_css, hyprland_border_commands_for, recolor_icon_text, recolor_kvantum_text,
    rofi_rasi_text, tint_icon_tree, tint_kvantum_tree,
};

use common::{make_icon_base, make_kvantum_base, tint_ctx, wallpaper};

const ACCENT: &str = "#ff00aa";
const ACCENT_DARK: &str = "#330044";
const ACCENT_LIGHT: &str = "#ffaadd";

// ── pure writers ─────────────────────────────────────────────────────────────

#[test]
fn rofi_rasi_replaces_accent_and_selected_bg() {
    let base = "* {\n  accent:      #7aa2f7;\n  selected-bg: #2d3252;\n  bg: #1a1b26;\n}\n";
    let out = rofi_rasi_text(base, ACCENT, ACCENT_DARK);
    assert!(out.contains("accent:      #ff00aa;"));
    assert!(out.contains("selected-bg: #330044;"));
    // untouched vars survive.
    assert!(out.contains("bg: #1a1b26;"));
}

#[test]
fn rofi_rasi_preserves_structure() {
    let base =
        "configuration { font: \"Lilex 12\"; }\n* { accent: #7aa2f7; }\nwindow { width: 720px; }\n";
    let out = rofi_rasi_text(base, ACCENT, ACCENT_DARK);
    assert!(out.contains("Lilex 12") && out.contains("width: 720px;"));
}

#[test]
fn gtk_css_v3_overrides_selection() {
    let css = gtk_css(ACCENT, ACCENT_DARK, ACCENT_LIGHT, 3);
    assert!(css.contains("@define-color theme_selected_bg_color #ff00aa;"));
    assert!(css.contains("@define-color theme_unfocused_selected_bg_color #330044;"));
    // v3 must NOT emit the gtk4-only accent_* colors.
    assert!(!css.contains("accent_bg_color"));
}

#[test]
fn gtk_css_v4_overrides_accent() {
    let css = gtk_css(ACCENT, ACCENT_DARK, ACCENT_LIGHT, 4);
    assert!(css.contains("@define-color accent_color #ff00aa;"));
    assert!(css.contains("@define-color accent_bg_color #ff00aa;"));
    assert!(css.contains("@define-color accent_fg_color #ffffff;"));
}

#[test]
fn hyprland_borders_skip_without_hyprland() {
    assert!(hyprland_border_commands_for(None, ACCENT, ACCENT_DARK).is_none());
}

#[test]
fn hyprland_borders_emit_two_keywords() {
    let cmds = hyprland_border_commands_for(Some("deadbeef"), ACCENT, ACCENT_DARK).unwrap();
    assert_eq!(cmds.len(), 2);
    assert_eq!(
        cmds[0],
        [
            "hyprctl",
            "keyword",
            "general:col.active_border",
            "rgba(#ff00aaff)"
        ]
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>()
    );
    assert_eq!(
        cmds[1],
        [
            "hyprctl",
            "keyword",
            "general:col.inactive_border",
            "rgba(#330044ff)"
        ]
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>()
    );
}

#[test]
fn recolor_kvantum_preserves_alpha_and_neutrals() {
    let sample = "x:#8CAAEE y:#839EDD z:#98B2EF alpha:#8CAAEE4D neutral:#303446 text:#C6D0F5";
    let out = recolor_kvantum_text(sample, ACCENT, ACCENT_DARK, ACCENT_LIGHT);
    assert!(out.contains("#ff00aa") && out.contains("#330044") && out.contains("#ffaadd"));
    assert!(
        out.contains("#ff00aa4D"),
        "trailing alpha hex must be preserved"
    );
    assert!(
        out.contains("#303446") && out.contains("#C6D0F5"),
        "neutrals/text untouched"
    );
    // original accents are gone (case-insensitive).
    assert!(!out.to_ascii_lowercase().contains("#8caaee"));
}

#[test]
fn recolor_icon_shifts_hue_keeps_lightness() {
    let sample = "a:#1c71d8 b:#438de6 c:#62a0ea d:#99c1f1 e:#afd4ff keep:#e78284";
    let out = recolor_icon_text(sample, ACCENT);
    let (ah, _, asat) = hex_to_hls(ACCENT);
    for orig in ["#1c71d8", "#438de6", "#62a0ea", "#99c1f1", "#afd4ff"] {
        let (_, ol, _) = hex_to_hls(orig);
        let expect = hls_to_hex(ah, ol, asat);
        assert!(
            out.contains(&expect),
            "{orig} -> {expect} (preserved lightness) missing"
        );
    }
    // a non-blue status color is left alone.
    assert!(out.contains("#e78284"));
}

// ── tree tinters ─────────────────────────────────────────────────────────────

#[test]
fn tint_kvantum_tree_renames_and_recolors() {
    let d = tempdir().unwrap();
    let base = make_kvantum_base(&d.path().join("base"));
    let dest = d.path().join("WallpaperTint");
    tint_kvantum_tree(&base, &dest, ACCENT, ACCENT_DARK, ACCENT_LIGHT).unwrap();
    assert!(dest.join("WallpaperTint.kvconfig").exists());
    assert!(dest.join("WallpaperTint.svg").exists());
    assert!(!dest.join("catppuccin-frappe-blue.kvconfig").exists());
    let kvc = fs::read_to_string(dest.join("WallpaperTint.kvconfig")).unwrap();
    assert!(
        kvc.to_ascii_lowercase()
            .contains("highlight.color=#ff00aa4d"),
        "alpha preserved"
    );
    assert!(!kvc.to_ascii_lowercase().contains("#8caaee"));
    let svg = fs::read_to_string(dest.join("WallpaperTint.svg")).unwrap();
    assert!(svg.to_ascii_lowercase().contains("#ff00aa") && svg.contains("#303446"));
}

#[test]
fn tint_icon_tree_rewrites_name_and_recolors() {
    let d = tempdir().unwrap();
    let base = make_icon_base(&d.path().join("base"));
    let dest = d.path().join("MoreWaita-Tint");
    tint_icon_tree(&base, &dest, ACCENT).unwrap();
    let idx = fs::read_to_string(dest.join("index.theme")).unwrap();
    assert!(idx.contains("Name=MoreWaita-Tint"));
    assert!(
        idx.contains("Inherits=Adwaita,AdwaitaLegacy,hicolor"),
        "Inherits line must survive"
    );
    let folder =
        fs::read_to_string(dest.join("scalable").join("places").join("folder.svg")).unwrap();
    assert!(!folder.to_ascii_lowercase().contains("#62a0ea"));
    assert!(!folder.to_ascii_lowercase().contains("#438de6"));
    // black (a non-blue) is preserved.
    let ruby =
        fs::read_to_string(dest.join("scalable").join("places").join("folder-ruby.svg")).unwrap();
    assert!(ruby.contains("#000000"));
}

// ── apply_tint orchestrator ──────────────────────────────────────────────────

fn ctx_with_bases(tmp: &Path) -> wallpaper_tui::tint::TintCtx {
    let kv = make_kvantum_base(&tmp.join("kvbase"));
    let ic = make_icon_base(&tmp.join("iconbase"));
    tint_ctx(tmp, Some(kv), Some(ic))
}

#[test]
fn apply_tint_generates_all_targets() {
    let d = tempdir().unwrap();
    let ctx = ctx_with_bases(d.path());
    let wp = wallpaper(d.path());
    let s = apply_tint_ctx(&ctx, wp.to_str().unwrap(), false, TintBackend::Internal).expect("ran");
    assert!(s.accent.starts_with('#'));
    assert_eq!(s.rofi, "ok");
    assert_eq!(s.gtk, "ok");
    assert_eq!(s.borders, "skipped"); // no HYPRLAND_INSTANCE_SIGNATURE
    assert_eq!(s.qt, "ok");
    assert_eq!(s.icons, "ok");
    assert!(ctx.kvantum_dest.join("WallpaperTint.kvconfig").exists());
    assert!(ctx.icon_dest.join("index.theme").exists());
    assert!(fs::read_to_string(ctx.icon_dest.join("index.theme"))
        .unwrap()
        .contains("Name=MoreWaita-Tint"));
    // kvconfig selector written; icon select disabled in tests -> icons_selected False.
    assert!(ctx.kvantum_select.exists());
    assert!(fs::read_to_string(&ctx.kvantum_select)
        .unwrap()
        .contains("theme=WallpaperTint"));
    assert!(!s.icons_selected);
    // tint state recorded.
    let state = TintState::load_from(ctx.tint_state_file());
    assert_eq!(state.accent, Some(s.accent.clone()));
}

#[test]
fn apply_tint_caches_svg_trees_on_same_accent() {
    let d = tempdir().unwrap();
    let ctx = ctx_with_bases(d.path());
    let wp = wallpaper(d.path());
    let wp = wp.to_str().unwrap();
    let first = apply_tint_ctx(&ctx, wp, false, TintBackend::Internal).unwrap();
    let second = apply_tint_ctx(&ctx, wp, false, TintBackend::Internal).unwrap();
    assert_eq!(first.accent, second.accent);
    assert_eq!(second.qt, "cached");
    assert_eq!(second.icons, "cached");
}

#[test]
fn apply_tint_no_tint_returns_none() {
    let d = tempdir().unwrap();
    let ctx = tint_ctx(d.path(), None, None);
    let wp = wallpaper(d.path());
    assert!(apply_tint_ctx(&ctx, wp.to_str().unwrap(), true, TintBackend::Internal).is_none());
}

#[test]
fn apply_tint_skips_missing_bases() {
    let d = tempdir().unwrap();
    let ctx = tint_ctx(d.path(), None, None); // no kvantum/icon base
    let wp = wallpaper(d.path());
    let s = apply_tint_ctx(&ctx, wp.to_str().unwrap(), false, TintBackend::Internal).unwrap();
    assert_eq!(s.qt, "skipped");
    assert_eq!(s.icons, "skipped");
    // cheap targets still ran.
    assert_eq!(s.rofi, "ok");
    assert_eq!(s.gtk, "ok");
}

#[test]
fn apply_tint_missing_path_is_noop() {
    let d = tempdir().unwrap();
    let ctx = tint_ctx(d.path(), None, None);
    assert!(apply_tint_ctx(&ctx, "/no/such/wp.png", false, TintBackend::Internal).is_none());
    let _ = Path::new("/no/such/wp.png");
}
