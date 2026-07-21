"""Pytest config: load the hyphen-named wallpaper-tui.py as a module.

The script lives at ``nix/home/wallpaper-tui.py``; the hyphen prevents a normal
import, so load it via importlib and expose it as the ``wt`` fixture. Pure
functions (extraction, writers, recolor) are tested without touching the real
home directory — every I/O test redirects the module-level paths to a tmp_path.
"""

import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "nix" / "home" / "wallpaper-tui.py"


@pytest.fixture(scope="session")
def wt():
    """The wallpaper-tui module, loaded from nix/home/wallpaper-tui.py."""
    spec = importlib.util.spec_from_file_location("wallpaper_tui", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def isolated_paths(wt, tmp_path, monkeypatch):
    """Redirect every module-level tint path into tmp_path and clear tint env.

    Returns the tmp_path so tests can assert on generated artifacts. The rofi
    base rasi is also pointed at a synthetic file under tmp_path.
    """
    tint_dir = tmp_path / "tint"
    monkeypatch.setattr(wt, "TINT_DIR", tint_dir, raising=False)
    monkeypatch.setattr(wt, "TINT_STATE", tint_dir / "current.json", raising=False)
    monkeypatch.setattr(wt, "KVANTUM_DEST", tmp_path / "Kvantum" / "WallpaperTint", raising=False)
    monkeypatch.setattr(wt, "KVANTUM_SELECT", tmp_path / "Kvantum" / "kvantum.kvconfig", raising=False)
    monkeypatch.setattr(wt, "ICON_DEST", tmp_path / "icons" / "MoreWaita-Tint", raising=False)
    monkeypatch.delenv("WALLPAPER_TUI_KVANTUM_BASE", raising=False)
    monkeypatch.delenv("WALLPAPER_TUI_ICON_BASE", raising=False)
    # No Hyprland, no gsettings on PATH → borders/icon-selector skip gracefully.
    monkeypatch.delenv("HYPRLAND_INSTANCE_SIGNATURE", raising=False)
    monkeypatch.setenv("PATH", "/bin:/usr/bin")
    # Point the rofi base at a synthetic rasi under tmp_path via XDG_CONFIG_HOME.
    rofi_dir = tmp_path / "xdg-config" / "rofi" / "themes"
    rofi_dir.mkdir(parents=True, exist_ok=True)
    (rofi_dir / "tokyonight.rasi").write_text(
        "* {\n  accent:      #7aa2f7;\n  selected-bg: #2d3252;\n  bg: #1a1b26;\n}\n"
    )
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg-config"))
    return tmp_path


def make_image(path, rgb, size=64):
    """Write a flat-color PNG using Pillow (imported lazily)."""
    from PIL import Image

    Image.new("RGB", (size, size), rgb).save(path)


def make_kvantum_base(root):
    """A minimal Kvantum theme tree mirroring catppuccin-frappe-blue's shape."""
    theme = root / "catppuccin-frappe-blue"
    theme.mkdir(parents=True, exist_ok=True)
    (theme / "catppuccin-frappe-blue.kvconfig").write_text(
        "[%General]\ncomment=Catppuccin-Frappe-Blue\n"
        "[GeneralColors]\nhighlight.color=#8CAAEE4D\nlink.color=#8CAAEE\nlink.visited.color=#98B2EF\n"
        "window.color=#303446\ntext.color=#C6D0F5\n"
    )
    (theme / "catppuccin-frappe-blue.svg").write_text(
        '<svg><rect fill="#8CAAEE"/><rect fill="#839EDD"/><rect fill="#303446"/></svg>\n'
    )
    return theme


def make_icon_base(root):
    """A minimal MoreWaita-shaped icon theme tree with the Adwaita-blue family."""
    theme = root / "MoreWaita"
    (theme / "scalable" / "places").mkdir(parents=True, exist_ok=True)
    (theme / "index.theme").write_text(
        "[Icon Theme]\nName=MoreWaita\nInherits=Adwaita,AdwaitaLegacy,hicolor\nExample=pamac\n"
    )
    (theme / "scalable" / "places" / "folder.svg").write_text(
        '<svg><stop stop-color="#62a0ea"/><stop stop-color="#afd4ff"/><rect fill="#438de6"/></svg>\n'
    )
    (theme / "scalable" / "places" / "folder-ruby.svg").write_text(
        '<svg><rect fill="#438de6"/><rect fill="#000000"/></svg>\n'
    )
    return theme