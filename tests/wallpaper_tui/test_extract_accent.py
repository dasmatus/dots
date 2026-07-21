"""Tests for extract_accent — the wallpaper → accent-color extractor.

Synthetic flat-color images pin the expected hue; the extractor's remap to a
fixed target lightness/saturation means we assert on *hue* (and that the result
is bright, not muddy) rather than exact hexes.
"""

import colorsys

from conftest import make_image


def _hue_of(wt, hexstr):
    return wt._hex_to_hls(hexstr)[0]


def _is_bright_enough(wt, hexstr):
    # accent should be remapped to L≈0.62, never near-black.
    _, light, _ = wt._hex_to_hls(hexstr)
    return 0.45 < light < 0.72


def test_solid_red_yields_red_hue(wt, tmp_path):
    p = tmp_path / "red.png"
    make_image(p, (220, 30, 30))
    accent, dark, light = wt.extract_accent(str(p))
    h = _hue_of(wt, accent)
    assert h < 0.04 or h > 0.96, f"red wallpaper -> hue {h}, expected ~0"
    assert _is_bright_enough(wt, accent), f"accent not bright: {accent}"


def test_solid_green_yields_green_hue(wt, tmp_path):
    p = tmp_path / "green.png"
    make_image(p, (40, 200, 60))
    accent, _, _ = wt.extract_accent(str(p))
    h = _hue_of(wt, accent)
    assert 0.28 < h < 0.38, f"green wallpaper -> hue {h}, expected ~0.33"


def test_solid_blue_yields_blue_hue(wt, tmp_path):
    p = tmp_path / "blue.png"
    make_image(p, (60, 120, 230))
    accent, _, _ = wt.extract_accent(str(p))
    h = _hue_of(wt, accent)
    assert 0.55 < h < 0.66, f"blue wallpaper -> hue {h}, expected ~0.6"


def test_shades_share_hue(wt, tmp_path):
    p = tmp_path / "magenta.png"
    make_image(p, (220, 40, 200))
    accent, dark, light = wt.extract_accent(str(p))
    ha, hd, hl = _hue_of(wt, accent), _hue_of(wt, dark), _hue_of(wt, light)
    # all three companions share the accent hue (within bucket resolution).
    assert max(ha, hd, hl) - min(ha, hd, hl) < 0.07
    # and span lightness: dark < accent < light.
    _, la, _ = wt._hex_to_hls(accent)
    _, ld, _ = wt._hex_to_hls(dark)
    _, ll, _ = wt._hex_to_hls(light)
    assert ld < la < ll


def test_grayscale_falls_back_to_default(wt, tmp_path):
    p = tmp_path / "gray.png"
    make_image(p, (128, 128, 128))
    accent, dark, light = wt.extract_accent(str(p))
    # no saturated pixels → buckets empty → default Tokyonight-blue accent.
    assert (accent, dark, light) == (wt.DEFAULT_ACCENT, wt.DEFAULT_ACCENT_DARK, wt.DEFAULT_ACCENT_LIGHT)


def test_near_black_falls_back_to_default(wt, tmp_path):
    p = tmp_path / "black.png"
    make_image(p, (5, 5, 5))
    assert wt.extract_accent(str(p)) == (wt.DEFAULT_ACCENT, wt.DEFAULT_ACCENT_DARK, wt.DEFAULT_ACCENT_LIGHT)


def test_missing_path_falls_back(wt):
    assert wt.extract_accent("/no/such/file.png") == (wt.DEFAULT_ACCENT, wt.DEFAULT_ACCENT_DARK, wt.DEFAULT_ACCENT_LIGHT)


def test_dominant_vibrant_beats_small_saturated_patch(wt, tmp_path):
    # A mostly-blue image with a small red patch: blue should win because the
    # extractor weights by saturation×frequency, not by raw saturation alone.
    from PIL import Image

    im = Image.new("RGB", (64, 64), (60, 120, 230))
    for x in range(8):
        for y in range(8):
            im.putpixel((x, y), (220, 30, 30))
    p = tmp_path / "mostly_blue.png"
    im.save(p)
    accent, _, _ = wt.extract_accent(str(p))
    h = _hue_of(wt, accent)
    assert 0.55 < h < 0.66, f"dominant blue should win, got hue {h} ({accent})"