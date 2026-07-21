"""Tests for the per-target tint writers and the apply_tint orchestrator.

Writers are pure (string in → string out); tree tints and apply_tint use the
``isolated_paths`` fixture + synthetic base themes from conftest so nothing
touches the real ~/.config or the Nix store.
"""

import os

from conftest import make_image, make_icon_base, make_kvantum_base

ACCENT = "#ff00aa"
ACCENT_DARK = "#330044"
ACCENT_LIGHT = "#ffaadd"


# ── pure writers ────────────────────────────────────────────────────────────


def test_rofi_rasi_replaces_accent_and_selected_bg(wt):
    base = "* {\n  accent:      #7aa2f7;\n  selected-bg: #2d3252;\n  bg: #1a1b26;\n}\n"
    out = wt.rofi_rasi_text(base, ACCENT, ACCENT_DARK)
    assert "accent:      #ff00aa;" in out
    assert "selected-bg: #330044;" in out
    # untouched vars survive.
    assert "bg: #1a1b26;" in out


def test_rofi_rasi_preserves_structure(wt):
    base = "configuration { font: \"Lilex 12\"; }\n* { accent: #7aa2f7; }\nwindow { width: 720px; }\n"
    out = wt.rofi_rasi_text(base, ACCENT, ACCENT_DARK)
    assert "Lilex 12" in out and "width: 720px;" in out


def test_gtk_css_v3_overrides_selection(wt):
    css = wt.gtk_css(ACCENT, ACCENT_DARK, ACCENT_LIGHT, 3)
    assert "@define-color theme_selected_bg_color #ff00aa;" in css
    assert "@define-color theme_unfocused_selected_bg_color #330044;" in css
    # v3 must NOT emit the gtk4-only accent_* colors.
    assert "accent_bg_color" not in css


def test_gtk_css_v4_overrides_accent(wt):
    css = wt.gtk_css(ACCENT, ACCENT_DARK, ACCENT_LIGHT, 4)
    assert "@define-color accent_color #ff00aa;" in css
    assert "@define-color accent_bg_color #ff00aa;" in css
    assert "@define-color accent_fg_color #ffffff;" in css


def test_hyprland_borders_skip_without_hyprland(wt, monkeypatch):
    monkeypatch.delenv("HYPRLAND_INSTANCE_SIGNATURE", raising=False)
    assert wt.hyprland_border_commands(ACCENT, ACCENT_DARK) is None


def test_hyprland_borders_emit_two_keywords(wt, monkeypatch):
    monkeypatch.setenv("HYPRLAND_INSTANCE_SIGNATURE", "deadbeef")
    cmds = wt.hyprland_border_commands(ACCENT, ACCENT_DARK)
    assert cmds is not None
    assert len(cmds) == 2
    assert cmds[0] == ["hyprctl", "keyword", "general:col.active_border", "rgba(#ff00aaff)"]
    assert cmds[1] == ["hyprctl", "keyword", "general:col.inactive_border", "rgba(#330044ff)"]


def test_recolor_kvantum_preserves_alpha_and_neutrals(wt):
    sample = "x:#8CAAEE y:#839EDD z:#98B2EF alpha:#8CAAEE4D neutral:#303446 text:#C6D0F5"
    out = wt._recolor_kvantum_text(sample, ACCENT, ACCENT_DARK, ACCENT_LIGHT)
    assert "#ff00aa" in out and "#330044" in out and "#ffaadd" in out
    assert "#ff00aa4D" in out, "trailing alpha hex must be preserved"
    assert "#303446" in out and "#C6D0F5" in out, "neutrals/text must be untouched"
    # original accents are gone (case-insensitive).
    assert "#8caaee" not in out.lower()


def test_recolor_icon_shifts_hue_keeps_lightness(wt):
    sample = "a:#1c71d8 b:#438de6 c:#62a0ea d:#99c1f1 e:#afd4ff keep:#e78284"
    out = wt._recolor_icon_text(sample, ACCENT)
    ah, _, asat = wt._hex_to_hls(ACCENT)
    for orig in ["#1c71d8", "#438de6", "#62a0ea", "#99c1f1", "#afd4ff"]:
        _, ol, _ = wt._hex_to_hls(orig)
        expect = wt._hls_to_hex(ah, ol, asat)
        assert expect in out, f"{orig} -> {expect} (preserved lightness) missing"
    # a non-blue status color is left alone.
    assert "#e78284" in out


# ── tree tinters ────────────────────────────────────────────────────────────


def test_tint_kvantum_tree_renames_and_recolors(wt, tmp_path):
    base = make_kvantum_base(tmp_path / "base")
    dest = tmp_path / "WallpaperTint"
    wt.tint_kvantum_tree(base, dest, ACCENT, ACCENT_DARK, ACCENT_LIGHT)
    assert (dest / "WallpaperTint.kvconfig").exists()
    assert (dest / "WallpaperTint.svg").exists()
    assert not (dest / "catppuccin-frappe-blue.kvconfig").exists()
    kvc = (dest / "WallpaperTint.kvconfig").read_text()
    assert "highlight.color=#ff00aa4d" in kvc.lower(), "alpha preserved in kvconfig"
    assert "#8caaee" not in kvc.lower()
    svg = (dest / "WallpaperTint.svg").read_text()
    assert "#ff00aa" in svg.lower() and "#303446" in svg


def test_tint_icon_tree_rewrites_name_and_recolors(wt, tmp_path):
    base = make_icon_base(tmp_path / "base")
    dest = tmp_path / "MoreWaita-Tint"
    wt.tint_icon_tree(base, dest, ACCENT)
    idx = (dest / "index.theme").read_text()
    assert "Name=MoreWaita-Tint" in idx
    assert "Inherits=Adwaita,AdwaitaLegacy,hicolor" in idx, "Inherits line must survive"
    folder = (dest / "scalable" / "places" / "folder.svg").read_text()
    assert "#62a0ea" not in folder.lower()
    assert "#438de6" not in folder.lower()
    # black (a non-blue) is preserved.
    ruby = (dest / "scalable" / "places" / "folder-ruby.svg").read_text()
    assert "#000000" in ruby


# ── apply_tint orchestrator ─────────────────────────────────────────────────


def _wallpaper(tmp_path):
    p = tmp_path / "wp.png"
    make_image(p, (40, 200, 60))
    return p


def test_apply_tint_generates_all_targets(wt, isolated_paths, tmp_path, monkeypatch):
    kv = make_kvantum_base(tmp_path / "kvbase")
    ic = make_icon_base(tmp_path / "iconbase")
    monkeypatch.setenv("WALLPAPER_TUI_KVANTUM_BASE", str(kv))
    monkeypatch.setenv("WALLPAPER_TUI_ICON_BASE", str(ic))
    r = wt.apply_tint(str(_wallpaper(tmp_path)))
    assert r["accent"].startswith("#")
    assert r["rofi"] == "ok"
    assert r["gtk"] == "ok"
    assert r["borders"] == "skipped"  # no HYPRLAND_INSTANCE_SIGNATURE
    assert r["qt"] == "ok"
    assert r["icons"] == "ok"
    assert (wt.KVANTUM_DEST / "WallpaperTint.kvconfig").exists()
    assert (wt.ICON_DEST / "index.theme").exists()
    assert "Name=MoreWaita-Tint" in (wt.ICON_DEST / "index.theme").read_text()
    # kvconfig selector written; gsettings absent on PATH -> icons_selected False.
    assert wt.KVANTUM_SELECT.exists() and "theme=WallpaperTint" in wt.KVANTUM_SELECT.read_text()
    assert r["icons_selected"] is False
    # tint state recorded.
    assert wt._load_tint_state()["accent"] == r["accent"]


def test_apply_tint_caches_svg_trees_on_same_accent(wt, isolated_paths, tmp_path, monkeypatch):
    kv = make_kvantum_base(tmp_path / "kvbase")
    ic = make_icon_base(tmp_path / "iconbase")
    monkeypatch.setenv("WALLPAPER_TUI_KVANTUM_BASE", str(kv))
    monkeypatch.setenv("WALLPAPER_TUI_ICON_BASE", str(ic))
    wp = str(_wallpaper(tmp_path))
    first = wt.apply_tint(wp)
    second = wt.apply_tint(wp)
    assert first["accent"] == second["accent"]
    assert second["qt"] == "cached"
    assert second["icons"] == "cached"


def test_apply_tint_no_tint_returns_empty(wt, isolated_paths, tmp_path):
    assert wt.apply_tint(str(_wallpaper(tmp_path)), no_tint=True) == {}


def test_apply_tint_skips_missing_bases(wt, isolated_paths, tmp_path):
    # no WALLPAPER_TUI_*_BASE env set (cleared by isolated_paths).
    r = wt.apply_tint(str(_wallpaper(tmp_path)))
    assert r["qt"] == "skipped"
    assert r["icons"] == "skipped"
    # cheap targets still ran.
    assert r["rofi"] == "ok" and r["gtk"] == "ok"


def test_apply_tint_missing_path_is_noop(wt, isolated_paths):
    assert wt.apply_tint("/no/such/wp.png") == {}