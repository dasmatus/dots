"""Tests for the awww backend: mode mapping, fill-color normalization, argv
building, and the apply_wallpaper orchestrator (subprocess stubbed)."""

from conftest import make_image


def test_map_resize_swaybg_to_awww(wt):
    assert wt.map_resize("fill") == "crop"
    assert wt.map_resize("stretch") == "stretch"
    assert wt.map_resize("fit") == "fit"
    assert wt.map_resize("center") == "no"
    assert wt.map_resize("tile") == "no", "tile unsupported -> centered"
    assert wt.map_resize("unknown") == "crop", "unknown -> crop default"


def test_normalize_fill_color(wt):
    assert wt._normalize_fill_color("#d2a1a1") == "d2a1a1ff"
    assert wt._normalize_fill_color("d2a1a1") == "d2a1a1ff"
    assert wt._normalize_fill_color("#000000ff") == "000000ff"
    assert wt._normalize_fill_color("") == "000000ff", "empty -> opaque black"


def test_awww_img_args_single_output(wt):
    g = {"output": "eDP-1", "path": "/w/p.jpg", "mode": "fit", "fill_color": "#d2a1a1"}
    args = wt.awww_img_args(g, "grow", 1.0)
    assert args[0:3] == ["awww", "img", "-o"]
    assert args[3] == "eDP-1"
    assert "/w/p.jpg" in args
    assert "--resize" in args and args[args.index("--resize") + 1] == "fit"
    assert "--fill-color" in args and args[args.index("--fill-color") + 1] == "d2a1a1ff"
    assert "--transition-type" in args and args[args.index("--transition-type") + 1] == "grow"
    assert "--transition-duration" in args and args[args.index("--transition-duration") + 1] == "1.0"


def test_awww_img_args_star_output_omits_o(wt):
    """The '*' (all-outputs) case must NOT pass -o: awww has no '*'."""
    g = {"output": "*", "path": "/w/p.jpg", "mode": "fill", "fill_color": "#000000"}
    args = wt.awww_img_args(g, "fade", 2.0)
    assert "-o" not in args
    assert "--outputs" not in args
    assert "/w/p.jpg" in args


def test_apply_wallpaper_spawns_one_img_per_group(wt, monkeypatch):
    spawns = []

    class FakePopen:
        def __init__(self, argv, **kwargs):
            spawns.append(argv)

    def fake_run(argv, **kwargs):
        # Simulate `awww query` succeeding -> daemon already up.
        return True

    monkeypatch.setattr(wt.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(wt.subprocess, "run", fake_run)
    monkeypatch.delenv("HYPRLAND_INSTANCE_SIGNATURE", raising=False)
    groups = [
        {"output": "eDP-1", "path": "/w/a.jpg", "mode": "fill", "fill_color": "#000000"},
        {"output": "HDMI-1", "path": "/w/b.jpg", "mode": "fit", "fill_color": "#d2a1a1"},
    ]
    procs = wt.apply_wallpaper(groups, transition_type="grow", transition_duration=1.0)
    assert len(procs) == 2
    assert len(spawns) == 2
    # Pin the integration: apply_wallpaper must pass awww_img_args's full argv
    # (mode mapping, fill-color, transition flags) through to Popen — not just
    # spawn N processes. Otherwise the orchestrator could silently drop flags
    # while the awww_img_args unit tests still pass in isolation.
    expected = [wt.awww_img_args(g, "grow", 1.0) for g in groups]
    assert spawns == expected
    assert spawns[0][0] == "awww" and spawns[0][1] == "img"
    assert spawns[1][3] == "HDMI-1"


def test_apply_wallpaper_empty_groups_noop(wt, monkeypatch):
    monkeypatch.setattr(wt.subprocess, "run", lambda *a, **k: True)
    assert wt.apply_wallpaper([]) == []