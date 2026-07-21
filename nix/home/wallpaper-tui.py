"""awww-based TUI wallpaper changer (waytrogen replacement).

Reads a declarative, read-only config (from Nix) for the wallpaper folder,
recursive flag, current output and per-output defaults, and a writable state
file for runtime overrides. ``--restore`` applies the effective merge of the
two.

After every apply (TUI pick, non-interactive ``--output/--path``, and
``--restore``) an accent color is extracted from the wallpaper and propagated
as a tint to four targets — Hyprland window borders, the Rofi theme, the GTK
3/4 theme accent, the Kvantum (Qt) theme, and the current icon theme. The tint
is accent-only: the curated Tokyonight/Catppuccin/MoreWaita bases are kept and
only their accent shade is moved toward the wallpaper's dominant vibrant hue.
Each target is best-effort and isolated, so a single target failing never
blocks setting the wallpaper. ``--no-tint`` skips the tint step entirely.

The base dirs for the SVG-based targets (Kvantum, icons) are injected via the
``WALLPAPER_TUI_KVANTUM_BASE`` / ``WALLPAPER_TUI_ICON_BASE`` env vars by the
Nix wrapper so the Python side stays free of store-path globbing and is
unit-testable with tmp dirs.
"""

import argparse
import colorsys
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Footer, Header, Label, ListItem, ListView, Static

CONFIG_FILE = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "wallpaper-tui" / "config.json"
STATE_FILE = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "wallpaper-tui" / "state.json"
EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
MODES = ["fill", "stretch", "fit", "center", "tile"]
# Tokyonight-adjacent palette for the `c` cycle (fill color for letterbox modes).
COLOR_PALETTE = [
    "#d2a1a1", "#1a1b26", "#000000", "#ffffff",
    "#7aa2f7", "#bb9af7", "#9ece6a", "#f7768e",
]
DEFAULT_COLOR = "#d2a1a1"

# ── Tint ───────────────────────────────────────────────────────────────────
# Tint artifacts live under STATE_DIR/tint/; GTK/Rofi pull them in via Nix
# @import of these files. TINT_STATE records the last accent so we can skip
# the expensive SVG-tree regen when the wallpaper yields the same accent.
STATE_DIR = STATE_FILE.parent
TINT_DIR = STATE_DIR / "tint"
TINT_STATE = TINT_DIR / "current.json"

# Fallback accent = Tokyonight blue (the rofi accent), so a failed extraction
# leaves the themes visually unchanged rather than blank.
DEFAULT_ACCENT = "#7aa2f7"
DEFAULT_ACCENT_DARK = "#3b4261"
DEFAULT_ACCENT_LIGHT = "#a9b1d6"

# Adwaita-blue family used by MoreWaita folder/place icons. Each is recolored
# to the accent's hue/saturation while keeping its own lightness, so the
# icon's gradient shading is preserved.
ADWAITA_BLUE_HEXES = [
    "#1c71d8", "#438de6", "#3584e4", "#62a0ea", "#99c1f1", "#afd4ff",
]
# Catppuccin-Frappe-Blue accents used by the Kvantum base theme. Replaced
# verbatim (case-insensitive); any trailing alpha hex (e.g. `#8CAAEE4D`) is
# preserved because only the 6-digit body is matched.
KVANTUM_ACCENT_HEXES = ["#8caaee", "#839edd", "#98b2ef"]

KVANTUM_DEST = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "Kvantum" / "WallpaperTint"
KVANTUM_SELECT = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "Kvantum" / "kvantum.kvconfig"
ICON_DEST = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "icons" / "MoreWaita-Tint"
ICON_THEME_NAME = "MoreWaita-Tint"


def load_config():
    """Read the declarative (read-only) config from Nix."""
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"wallpaper_folder": "", "recursive": True, "current_output": "", "outputs": {}}


def load_state():
    """Read runtime override state (writable; may not exist yet)."""
    try:
        return json.loads(STATE_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"outputs": {}}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def list_wallpapers(folder, recursive):
    if not folder or not Path(folder).is_dir():
        return []
    it = Path(folder).rglob("*") if recursive else Path(folder).iterdir()
    paths = [p for p in it if p.is_file() and p.suffix.lower() in EXTENSIONS]
    # Newest first — matches waytrogen's sort_by: Date default.
    paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return paths


def detect_outputs():
    """Best-effort output enumeration via hyprctl; falls back to []."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return []
    try:
        out = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True,
            text=True,
            check=True,
        )
        return [m["name"] for m in json.loads(out.stdout)]
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError, KeyError):
        return []


def effective_output(config, state, output):
    """Merge declarative defaults with runtime overrides for one output."""
    decl = config.get("outputs", {}).get(output, {})
    over = state.get("outputs", {}).get(output, {})
    return {
        "path": over.get("path") or decl.get("path") or "",
        "mode": over.get("mode") or decl.get("mode") or "fill",
        "fill_color": over.get("fill_color") or decl.get("fill_color") or DEFAULT_COLOR,
    }


SWWW_RESIZE = {
    "fill": "crop",
    "stretch": "stretch",
    "fit": "fit",
    "center": "no",
    "tile": "no",
}
TRANSITION_TYPES = [
    "none", "simple", "fade", "left", "right", "top", "bottom",
    "wipe", "wave", "grow", "center", "any", "outer", "random",
]


def map_resize(mode):
    """Map a swaybg scaling mode to an awww ``--resize`` value.

    awww has no ``tile`` (degrades to centered ``no``); it does support
    ``stretch`` (distort) directly, unlike swww. Unknown modes default to
    ``crop`` (fill).
    """
    return SWWW_RESIZE.get(mode, "crop")


def _normalize_fill_color(color):
    """Normalize a ``#rrggbb``/``rrggbb``/``#rrggbbaa`` fill color to bare ``RRGGBBAA``.

    awww's ``--fill-color`` takes an 8-digit RGBA hex (default ``000000ff``),
    no leading ``#``. Empty input falls back to opaque black.
    """
    c = (color or "").lstrip("#")
    if not c:
        return "000000ff"
    if len(c) == 6:
        c += "ff"
    return c.lower()


def awww_img_args(group, transition_type, transition_duration):
    """Build the argv for one ``awww img`` IPC command for a single output group.

    ``-o`` is omitted for the ``*``/all-outputs case (awww has no ``*``; an
    empty ``--outputs`` list means all outputs). ``fill_color`` is normalized
    to ``RRGGBBAA``.
    """
    args = ["awww", "img"]
    if group.get("output") and group["output"] != "*":
        args += ["-o", group["output"]]
    args += [
        group["path"],
        "--resize", map_resize(group.get("mode", "fill")),
        "--fill-color", _normalize_fill_color(group.get("fill_color", "")),
        "--transition-type", transition_type,
        "--transition-duration", str(transition_duration),
    ]
    return args


def ensure_awww_daemon():
    """Best-effort: make sure ``awww-daemon`` is running before sending img IPC.

    awww has no ``init`` subcommand (unlike swww). ``awww query`` returns
    nonzero if the daemon is down; in that case spawn ``awww-daemon`` detached
    (setsid-equivalent) and give it a moment. hyprland.start also exec-onces
    the daemon, so this is a defensive fallback for manual ``--restore`` from
    a terminal. Never raises.
    """
    try:
        subprocess.run(["awww", "query"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    except (subprocess.CalledProcessError, OSError):
        pass
    try:
        subprocess.Popen(["awww-daemon"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        import time
        time.sleep(0.3)
    except OSError:
        pass


def apply_wallpaper(groups, transition_type="grow", transition_duration=1.0):
    """Apply `groups` via the awww daemon (one ``awww img`` per output).

    awww is IPC-driven: one persistent ``awww-daemon`` holds the wallpaper, so
    (unlike swaybg) there is no kill+respawn per apply. ``ensure_awww_daemon``
    starts the daemon if it isn't already up. Each ``awww img`` is a short-lived
    IPC client that returns once the transition begins. Returns the list of
    spawned Popen objects (one per group), or [] if there was nothing to apply.
    """
    if not groups:
        return []
    ensure_awww_daemon()
    procs = []
    for g in groups:
        procs.append(subprocess.Popen(
            awww_img_args(g, transition_type, transition_duration),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    return procs


# ── Tint: palette extraction ───────────────────────────────────────────────


def _hex_to_rgb(hexstr):
    h = hexstr.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _rgb_to_hex(rgb):
    return "#" + "".join(f"{int(round(c * 255)):02x}" for c in rgb)


def _hex_to_hls(hexstr):
    r, g, b = _hex_to_rgb(hexstr)
    return colorsys.rgb_to_hls(r / 255, g / 255, b / 255)


def _hls_to_hex(h, light, s):
    return _rgb_to_hex(colorsys.hls_to_rgb(h, light, s))


def extract_accent(path):
    """Derive ``(accent, accent_dark, accent_light)`` hex strings from `path`.

    Downsamples to 64x64, drops near-black/white/low-saturation pixels, buckets
    the rest by hue, and picks the bucket with the largest saturation-weighted
    population. The winning hue is remapped to a fixed target lightness/
    saturation (0.62/0.55) so the accent is always a usable UI color regardless
    of the wallpaper's original lightness. Dark/light companions share the hue
    and saturation at L=0.40 / L=0.78. Any error falls back to DEFAULT_ACCENT.
    """
    try:
        from PIL import Image
    except ImportError:
        return (DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT)
    try:
        with Image.open(path) as im:
            im = im.convert("RGB")
            im.thumbnail((64, 64))
            # tobytes() over getdata(): stable across Pillow versions (getdata is
            # deprecated for removal in Pillow 14) and faster for a flat byte run.
            data = im.tobytes()
            px = [(data[i], data[i + 1], data[i + 2]) for i in range(0, len(data), 3)]
    except Exception:
        return (DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT)
    if not px:
        return (DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT)
    # buckets: hue bin -> [weight, hue_sum, count]
    buckets = {}
    for r, g, b in px:
        h, light, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        if light < 0.1 or light > 0.9 or s < 0.2:
            continue
        hbin = int(h * 16) % 16
        e = buckets.setdefault(hbin, [0.0, 0.0, 0])
        e[0] += s          # saturation-weighted frequency
        e[1] += h
        e[2] += 1
    if not buckets:
        return (DEFAULT_ACCENT, DEFAULT_ACCENT_DARK, DEFAULT_ACCENT_LIGHT)
    best_bin = max(buckets, key=lambda k: buckets[k][0])
    _, h_sum, cnt = buckets[best_bin]
    hue = h_sum / cnt
    accent = _hls_to_hex(hue, 0.62, 0.55)
    accent_dark = _hls_to_hex(hue, 0.40, 0.55)
    accent_light = _hls_to_hex(hue, 0.78, 0.55)
    return (accent, accent_dark, accent_light)


# ── Tint: per-target writers (pure) ────────────────────────────────────────


def rofi_rasi_text(base_text, accent, accent_dark):
    """Substitute the ``accent:`` and ``selected-bg:`` rasi vars in the base."""
    text = re.sub(r"(accent:\s*)#[0-9a-fA-F]{6};", rf"\g<1>{accent};", base_text)
    text = re.sub(r"(selected-bg:\s*)#[0-9a-fA-F]{6};", rf"\g<1>{accent_dark};", text)
    return text


def gtk_css(accent, accent_dark, accent_light, version):
    """``@define-color`` overrides loaded after the Tokyonight theme import."""
    if version == 4:
        return (
            f"/* wallpaper-tui accent tint — overrides Tokyonight accent. */\n"
            f"@define-color theme_selected_bg_color {accent};\n"
            f"@define-color theme_selected_fg_color #ffffff;\n"
            f"@define-color accent_color {accent};\n"
            f"@define-color accent_bg_color {accent};\n"
            f"@define-color accent_fg_color #ffffff;\n"
        )
    return (
        f"/* wallpaper-tui accent tint — overrides Tokyonight selection. */\n"
        f"@define-color theme_selected_bg_color {accent};\n"
        f"@define-color theme_selected_fg_color #ffffff;\n"
        f"@define-color theme_selected_borders_color {accent_dark};\n"
        f"@define-color theme_unfocused_selected_bg_color {accent_dark};\n"
    )


def hyprland_border_commands(accent, accent_dark):
    """Return argv lists for ``hyprctl keyword`` border colors, or None."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    return [
        ["hyprctl", "keyword", "general:col.active_border", f"rgba({accent}ff)"],
        ["hyprctl", "keyword", "general:col.inactive_border", f"rgba({accent_dark}ff)"],
    ]


def _recolor_kvantum_text(text, accent, accent_dark, accent_light):
    """Replace the Catppuccin-Frappe accent family; preserve trailing alpha."""
    for orig, repl in zip(KVANTUM_ACCENT_HEXES, (accent, accent_dark, accent_light)):
        text = re.sub(re.escape(orig), repl, text, flags=re.IGNORECASE)
    return text


def _recolor_icon_text(text, accent):
    """Recolor the Adwaita-blue family to the accent hue/sat, keeping lightness."""
    ah, _, asat = _hex_to_hls(accent)

    def repl(m):
        _, ol, _ = _hex_to_hls(m.group(0))
        return _hls_to_hex(ah, ol, asat)

    pattern = re.compile("|".join(re.escape(b) for b in ADWAITA_BLUE_HEXES), re.IGNORECASE)
    return pattern.sub(repl, text)


def _writable_copytree(src, dst):
    """copytree whose output is owner-writable.

    The Kvantum/icon bases live in the read-only Nix store; a plain
    ``shutil.copytree`` copies their 0555/0444 mode bits, making the
    destination read-only so the subsequent recolor/rename writes fail.
    Copying file *content* only (``copyfile``) and chmod-ing the tree to
    0755/0644 yields a writable copy we can edit in place.
    """
    shutil.copytree(src, dst, copy_function=shutil.copyfile)
    for root, dirs, files in os.walk(dst):
        os.chmod(root, 0o755)
        for f in files:
            os.chmod(os.path.join(root, f), 0o644)


def _rename_theme_files(dest, base_name, new_name):
    """Rename ``<base>.kvconfig``/``<base>.svg`` → ``<new>.*`` and rewrite refs."""
    for ext in (".kvconfig", ".svg"):
        src = dest / f"{base_name}{ext}"
        if src.exists():
            txt = src.read_text()
            txt = txt.replace(base_name, new_name)
            src.write_text(txt)
            src.rename(dest / f"{new_name}{ext}")


def tint_kvantum_tree(base, dest, accent, accent_dark, accent_light):
    """Copy the base Kvantum theme to `dest` and recolor its accent family."""
    base = Path(base)
    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    _writable_copytree(base, dest)
    base_name = base.name
    _rename_theme_files(dest, base_name, "WallpaperTint")
    for p in dest.iterdir():
        if p.is_file() and p.suffix in (".kvconfig", ".svg"):
            p.write_text(_recolor_kvantum_text(p.read_text(), accent, accent_dark, accent_light))


def tint_icon_tree(base, dest, accent):
    """Copy the icon theme to `dest`, recolor the Adwaita-blue family, rename."""
    base = Path(base)
    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    _writable_copytree(base, dest)
    for p in dest.rglob("*.svg"):
        p.write_text(_recolor_icon_text(p.read_text(), accent))
    idx = dest / "index.theme"
    if idx.exists():
        txt = idx.read_text()
        txt = re.sub(r"(?m)^Name=.*$", f"Name={ICON_THEME_NAME}", txt)
        idx.write_text(txt)


# ── Tint: I/O + selectors ──────────────────────────────────────────────────


def _rofi_base_path():
    """The read-only Tokyonight rasi installed by rofi/default.nix."""
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "rofi" / "themes" / "tokyonight.rasi"


def _write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _load_tint_state():
    try:
        return json.loads(TINT_STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def _save_tint_state(data):
    TINT_DIR.mkdir(parents=True, exist_ok=True)
    TINT_STATE.write_text(json.dumps(data, indent=2) + "\n")


def _select_kvantum():
    """Point ``kvantum.kvconfig`` at WallpaperTint (no-op if dest missing)."""
    if not KVANTUM_DEST.exists():
        return False
    KVANTUM_SELECT.parent.mkdir(parents=True, exist_ok=True)
    KVANTUM_SELECT.write_text("[General]\ntheme=WallpaperTint\n")
    return True


def _select_icon_theme():
    """gsettings-switch to MoreWaita-Tint (no-op if dest missing or no gsettings)."""
    if not ICON_DEST.exists():
        return False
    try:
        subprocess.run(["gsettings", "set", "org.gnome.desktop.interface", "icon-theme", ICON_THEME_NAME], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError:
        return False


def apply_tint(path, *, no_tint=False):
    """Best-effort accent tint of borders/Rofi/GTK/Kvantum/icons from `path`.

    Each target is isolated: a failure is recorded in the returned status dict
    and the rest continue. Heavy SVG-tree regen is skipped when the accent is
    unchanged since the last apply, but the cheap selectors (hyprctl keyword,
    gsettings, kvconfig) always re-run so a HM rebuild that reset them is
    corrected on the next tint.
    """
    if no_tint or not path:
        return {}
    if not Path(path).exists():
        return {}
    result = {}
    accent, accent_dark, accent_light = extract_accent(path)
    result["accent"] = accent
    TINT_DIR.mkdir(parents=True, exist_ok=True)
    same_accent = _load_tint_state().get("accent") == accent

    # Rofi — cheap text file, always regenerate.
    try:
        base = _rofi_base_path()
        if base.exists():
            _write_text(TINT_DIR / "rofi.rasi", rofi_rasi_text(base.read_text(), accent, accent_dark))
            result["rofi"] = "ok"
        else:
            result["rofi"] = "skipped"
    except Exception as e:  # noqa: BLE001 — best-effort
        result["rofi"] = f"error: {e}"

    # GTK 3/4 — cheap CSS files, always regenerate.
    try:
        _write_text(TINT_DIR / "gtk3.css", gtk_css(accent, accent_dark, accent_light, 3))
        _write_text(TINT_DIR / "gtk4.css", gtk_css(accent, accent_dark, accent_light, 4))
        result["gtk"] = "ok"
    except Exception as e:  # noqa: BLE001
        result["gtk"] = f"error: {e}"

    # Hyprland borders — runtime hyprctl keyword, always re-apply.
    try:
        cmds = hyprland_border_commands(accent, accent_dark)
        if cmds is None:
            result["borders"] = "skipped"
        else:
            for c in cmds:
                subprocess.run(c, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            result["borders"] = "ok"
    except Exception as e:  # noqa: BLE001
        result["borders"] = f"error: {e}"

    # Kvantum (Qt) — expensive SVG copy, only regen on accent change.
    kvantum_base = os.environ.get("WALLPAPER_TUI_KVANTUM_BASE", "")
    if kvantum_base and Path(kvantum_base).is_dir():
        if not same_accent or not KVANTUM_DEST.exists():
            try:
                tint_kvantum_tree(kvantum_base, KVANTUM_DEST, accent, accent_dark, accent_light)
                result["qt"] = "ok"
            except Exception as e:  # noqa: BLE001
                result["qt"] = f"error: {e}"
        else:
            result["qt"] = "cached"
        result["qt_selected"] = _select_kvantum()
    else:
        result["qt"] = "skipped"

    # Icons — expensive SVG tree, only regen on accent change.
    icon_base = os.environ.get("WALLPAPER_TUI_ICON_BASE", "")
    if icon_base and Path(icon_base).is_dir():
        if not same_accent or not ICON_DEST.exists():
            try:
                tint_icon_tree(icon_base, ICON_DEST, accent)
                result["icons"] = "ok"
            except Exception as e:  # noqa: BLE001
                result["icons"] = f"error: {e}"
        else:
            result["icons"] = "cached"
        result["icons_selected"] = _select_icon_theme()
    else:
        result["icons"] = "skipped"

    _save_tint_state({"accent": accent, "source_path": str(path)})
    print(f"wallpaper-tui: tint {accent} — {result}", file=sys.stderr)
    return result


def restore_all(config, state, *, no_tint=False):
    """Re-apply every declared output, using overrides where present."""
    groups = []
    for output in config.get("outputs", {}):
        eff = effective_output(config, state, output)
        if eff["path"] and Path(eff["path"]).exists():
            groups.append({"output": output, **eff})
    if not groups:
        print("wallpaper-tui: nothing to restore.", file=sys.stderr)
        return 1
    apply_wallpaper(
        groups,
        transition_type=config.get("transition_type", "grow"),
        transition_duration=config.get("transition_duration", 1.0),
    )
    # Tint from the first output's wallpaper; on a multi-monitor setup the
    # accent follows the primary/first-declared output.
    apply_tint(groups[0]["path"], no_tint=no_tint)
    print(f"wallpaper-tui: restored {len(groups)} output(s).", file=sys.stderr)
    return 0


# ── Preview (chafa -> Rich Text) ───────────────────────────────────────────
# alacritty supports no image protocol, so previews render as chafa unicode-art
# (block symbols) parsed from ANSI into a Rich Text that a Textual Static can
# display. chafa is forced to --format=ansi --symbols=block so output is
# deterministic regardless of whether stdout is a tty. The thumbnail cache
# (cache_previews, below) feeds _thumb_for so the TUI decodes a 320x200 PNG
# instead of a full-res image on every cursor move.

PREVIEW_CACHE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "wallpaper-tui" / "thumbs"


def _apply_sgr(params, style):
    """Apply one SGR parameter list (``"38;2;r;g;b;48;2;r;g;b"``) to a Rich Style.

    Handles the subset chafa emits: 24-bit fg (``38;2;...``), 24-bit bg
    (``48;2;...``), and ``0`` reset. Unknown params (bold, etc.) are tolerated
    -- the current colors are kept so a chafa version change can't break
    rendering.
    """
    from rich.style import Style
    from rich.color import Color

    parts = [p for p in params.split(";") if p != ""]
    if not parts or parts == ["0"]:
        return Style()
    fg = style.color
    bg = style.bgcolor
    k = 0
    while k < len(parts):
        p = parts[k]
        if p == "0":
            fg = None
            bg = None
        elif p == "38" and k + 4 < len(parts) and parts[k + 1] == "2":
            fg = Color.from_rgb(int(parts[k + 2]), int(parts[k + 3]), int(parts[k + 4]))
            k += 4
        elif p == "48" and k + 4 < len(parts) and parts[k + 1] == "2":
            bg = Color.from_rgb(int(parts[k + 2]), int(parts[k + 3]), int(parts[k + 4]))
            k += 4
        # else: unknown SGR -- ignore, keep current colors.
        k += 1
    return Style(color=fg, bgcolor=bg)


def ansi_to_textual(ansi):
    """Parse chafa's ANSI SGR stream into a Rich Text with per-cell colors.

    Handles combined ``38;2;r;g;b;48;2;r;g;b`` SGR sequences, ``0`` reset, and
    skips non-SGR CSI sequences (the ``?25l``/``?25h`` cursor private modes).
    Non-CSI bytes are appended as plain text (UTF-8 block glyphs included).
    Returns a ``rich.text.Text`` safe to feed ``Static.update()``.
    """
    from rich.text import Text
    from rich.style import Style

    text = Text()
    style = Style()
    i = 0
    n = len(ansi)
    while i < n:
        if ansi[i] == "\x1b" and i + 1 < n and ansi[i + 1] == "[":
            j = i + 2
            while j < n and not (0x40 <= ord(ansi[j]) <= 0x7E):
                j += 1
            if j >= n:
                break
            if ansi[j] == "m":
                style = _apply_sgr(ansi[i + 2:j], style)
            # else: non-SGR CSI (e.g. ?25l/?25h) -> skip, emit no text.
            i = j + 1
        elif ansi[i] == "\x1b":
            # Lone/trailing ESC or a non-CSI escape (e.g. ESC(B, ESC=):
            # skip the ESC byte (and, for a 2-byte Fe/Fp escape, its one
            # following byte) so the outer loop always advances. Never
            # append the raw control byte as text.
            i += 2 if (i + 1 < n and 0x30 <= ord(ansi[i + 1]) <= 0x7E) else 1
        else:
            k = i
            while k < n and ansi[k] != "\x1b":
                k += 1
            text.append(ansi[i:k], style=style)
            i = k
    return text


def render_preview_ansi(path, cols, rows):
    """Run chafa on `path` (a wallpaper or cached thumbnail) -> ANSI string.

    Forced flags keep output deterministic in a non-tty pipe. Returns "" on
    any failure (caller shows a placeholder).
    """
    try:
        out = subprocess.run(
            ["chafa", "--format=ansi", "--symbols=block",
             f"--size={cols}x{rows}", "--color-space=rgb",
             "--dither=ordered", str(path)],
            capture_output=True, text=True, check=True,
        )
        return out.stdout
    except (subprocess.CalledProcessError, OSError):
        return ""


def _thumb_for(path):
    """Return the cached thumbnail path for `path` if it exists, else `path`."""
    import hashlib

    key = hashlib.sha1(f"{path}:{Path(path).stat().st_mtime}".encode()).hexdigest()
    thumb = PREVIEW_CACHE / f"{key}.png"
    return str(thumb) if thumb.exists() else str(path)


def cache_previews(folder, recursive, out_dir, size=(320, 200)):
    """Generate/refresh downsampled PNG thumbnails for every wallpaper.

    Idempotent + mtime-skipped: a thumbnail is regenerated only when the
    source's mtime is newer than the cached one (or the cache is missing).
    Returns ``{"written": n, "skipped": m}``. Unreadable images are skipped
    with a stderr warning and never crash the run.
    """
    import hashlib
    import os
    import tempfile
    from PIL import Image

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    skipped = 0
    for p in list_wallpapers(folder, recursive):
        key = hashlib.sha1(f"{p}:{p.stat().st_mtime}".encode()).hexdigest()
        thumb = out_dir / f"{key}.png"
        if thumb.exists() and thumb.stat().st_mtime >= p.stat().st_mtime:
            skipped += 1
            continue
        # Write to a sibling temp then os.replace onto `thumb` so a failed/
        # interrupted save never leaves a partial PNG that the mtime-skip
        # guard would then treat as valid forever.
        fd, tmp = tempfile.mkstemp(prefix=f"{key}.", suffix=".png", dir=str(out_dir))
        os.close(fd)
        try:
            with Image.open(p) as im:
                im = im.convert("RGB")
                im.thumbnail(size)
                im.save(tmp, "PNG")
            os.replace(tmp, thumb)
            written += 1
        except Exception as e:  # noqa: BLE001 -- best-effort
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print(f"wallpaper-tui: cache skip {p}: {e}", file=sys.stderr)
    return {"written": written, "skipped": skipped}


class Preview(Static):
    """Chafa-rendered unicode-art preview of the currently-selected wallpaper."""

    PREVIEW_COLS = 48
    PREVIEW_ROWS = 20

    def show_path(self, path):
        """Render `path` (cached thumbnail preferred) into this widget."""
        from rich.text import Text

        # Plain Text (not a bare str) so the bracketed placeholder is shown
        # literally instead of being parsed as Rich markup and rendered blank.
        if not path or not Path(path).exists():
            self.update(Text("[preview unavailable]"))
            return
        ansi = render_preview_ansi(_thumb_for(path), self.PREVIEW_COLS, self.PREVIEW_ROWS)
        if not ansi:
            self.update(Text("[preview unavailable]"))
            return
        self.update(ansi_to_textual(ansi))


class WallpaperTUI(App):
    """Textual picker: browse wallpapers, tune mode/color/output, apply."""

    # Size the horizontal layout: the list takes the remaining space (1fr) and
    # the chafa preview pane gets a fixed 52-col width (~48 glyph cols + a
    # little padding) and full height. Without this, Horizontal would collapse
    # the preview to zero width beside the list.
    CSS = """
    Horizontal { height: 1fr; }
    #list { width: 1fr; }
    #preview { width: 52; height: 1fr; padding: 0 1; border: round $accent; }
    """

    BINDINGS = [
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("enter", "apply", "Apply"),
        Binding("m", "cycle_mode", "Mode"),
        Binding("c", "set_color", "Color"),
        Binding("o", "cycle_output", "Output"),
        Binding("p", "toggle_preview", "Preview"),
        Binding("r", "restore", "Restore"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, config, state, *, no_tint=False):
        super().__init__()
        self.config = config
        self.state = state
        self.no_tint = no_tint
        self.outputs = detect_outputs()
        for name in self.config.get("outputs", {}):
            if name not in self.outputs:
                self.outputs.append(name)
        if not self.outputs:
            self.outputs = ["*"]
        cur = self.config.get("current_output", "") or ""
        if cur not in self.outputs:
            cur = self.outputs[0]
        self.current_output = cur
        eff = effective_output(self.config, self.state, self.current_output)
        self.fill_mode = eff["mode"]
        self.current_color = eff["fill_color"]
        self.wallpapers = list_wallpapers(
            self.config.get("wallpaper_folder", ""),
            self.config.get("recursive", True),
        )
        self._preview_cache = {}
        self._show_preview = True

    def output_state(self):
        return self.state.setdefault("outputs", {}).setdefault(self.current_output, {})

    def compose(self) -> ComposeResult:
        yield Header()
        if self.wallpapers:
            yield Horizontal(
                ListView(
                    *[ListItem(Label(p.name), name=str(p)) for p in self.wallpapers],
                    id="list",
                ),
                Preview(id="preview"),
            )
        else:
            yield Label(
                f"No wallpapers found in: {self.config.get('wallpaper_folder', '?')}",
                id="empty",
            )
        yield Static(self.info_text(), id="info")
        yield Footer()

    def on_mount(self) -> None:
        self._refresh_preview()

    def info_text(self):
        eff = effective_output(self.config, self.state, self.current_output)
        path = eff["path"]
        name = Path(path).name if path else "(none)"
        return (
            f" Output: {self.current_output} | Mode: {self.fill_mode} "
            f"| Color: {self.current_color} | Current: {name} "
        )

    def refresh_info(self):
        self.query_one("#info", Static).update(self.info_text())

    def selected_path(self):
        try:
            lv = self.query_one("#list", ListView)
        except Exception:
            return None
        child = lv.highlighted_child
        return child.name if child is not None else None

    def _refresh_preview(self):
        """Re-render the preview pane for the current selection (memoized)."""
        if not self._show_preview:
            return
        try:
            preview = self.query_one("#preview", Preview)
        except Exception:
            return
        path = self.selected_path()
        if not path:
            return
        ansi = self._preview_cache.get(path, "")
        if not ansi and path not in self._preview_cache:
            ansi = render_preview_ansi(_thumb_for(path), Preview.PREVIEW_COLS, Preview.PREVIEW_ROWS)
            self._preview_cache[path] = ansi
        if ansi:
            preview.update(ansi_to_textual(ansi))
        else:
            preview.show_path(path)

    def on_list_view_selected(self, event):
        # Enter/click on a list row → apply it to the current output.
        self._refresh_preview()
        self.action_apply()

    def action_cursor_up(self):
        lv = self.query_one("#list", ListView)
        if lv.highlighted is None:
            lv.highlighted = len(lv.children) - 1
        elif lv.highlighted > 0:
            lv.highlighted -= 1
        self._refresh_preview()

    def action_cursor_down(self):
        lv = self.query_one("#list", ListView)
        if lv.highlighted is None:
            lv.highlighted = 0
        elif lv.highlighted < len(lv.children) - 1:
            lv.highlighted += 1
        self._refresh_preview()

    def action_cycle_mode(self):
        idx = MODES.index(self.fill_mode) if self.fill_mode in MODES else 0
        self.fill_mode = MODES[(idx + 1) % len(MODES)]
        self.refresh_info()

    def action_cycle_output(self):
        idx = self.outputs.index(self.current_output) if self.current_output in self.outputs else 0
        self.current_output = self.outputs[(idx + 1) % len(self.outputs)]
        eff = effective_output(self.config, self.state, self.current_output)
        self.fill_mode = eff["mode"]
        self.current_color = eff["fill_color"]
        self.refresh_info()

    def action_set_color(self):
        idx = COLOR_PALETTE.index(self.current_color) if self.current_color in COLOR_PALETTE else -1
        self.current_color = COLOR_PALETTE[(idx + 1) % len(COLOR_PALETTE)]
        self.refresh_info()

    def action_apply(self):
        path = self.selected_path()
        if not path:
            return
        st = self.output_state()
        st["path"] = path
        st["mode"] = self.fill_mode
        st["fill_color"] = self.current_color
        save_state(self.state)
        apply_wallpaper(
            [{
                "output": self.current_output,
                "path": path,
                "mode": self.fill_mode,
                "fill_color": self.current_color,
            }],
            transition_type=self.config.get("transition_type", "grow"),
            transition_duration=self.config.get("transition_duration", 1.0),
        )
        apply_tint(path, no_tint=self.no_tint)
        self.refresh_info()

    def action_restore(self):
        restore_all(self.config, self.state, no_tint=self.no_tint)

    def action_toggle_preview(self):
        self._show_preview = not self._show_preview
        try:
            self.query_one("#preview", Preview).display = self._show_preview
        except Exception:
            pass

    def action_quit(self):
        self.exit()


def main():
    parser = argparse.ArgumentParser(description="awww-based TUI wallpaper changer")
    parser.add_argument("--restore", action="store_true", help="re-apply effective wallpapers and exit")
    parser.add_argument("--output", help="output name (non-interactive apply)")
    parser.add_argument("--mode", choices=MODES, default="fill")
    parser.add_argument("--color", default=DEFAULT_COLOR)
    parser.add_argument("--no-tint", action="store_true", help="skip wallpaper-derived accent tinting")
    parser.add_argument("--cache-previews", action="store_true", help="regenerate the wallpaper thumbnail cache and exit")
    parser.add_argument("--preview-size", default="320x200", help="thumbnail size WxH for --cache-previews")
    parser.add_argument("path", nargs="?", help="wallpaper path (non-interactive apply)")
    args = parser.parse_args()

    config = load_config()
    state = load_state()

    if args.restore:
        sys.exit(restore_all(config, state, no_tint=args.no_tint))

    if args.cache_previews:
        w, h = (int(x) for x in args.preview_size.lower().split("x"))
        r = cache_previews(config.get("wallpaper_folder", ""),
                           config.get("recursive", True), PREVIEW_CACHE, size=(w, h))
        print(f"wallpaper-tui: cached {r['written']} new, skipped {r['skipped']}.", file=sys.stderr)
        return

    if args.path:
        if not args.output:
            parser.error("--output is required when a path is given")
        state.setdefault("outputs", {})[args.output] = {
            "path": args.path,
            "mode": args.mode,
            "fill_color": args.color,
        }
        save_state(state)
        apply_wallpaper(
            [{
                "output": args.output,
                "path": args.path,
                "mode": args.mode,
                "fill_color": args.color,
            }],
            transition_type=config.get("transition_type", "grow"),
            transition_duration=config.get("transition_duration", 1.0),
        )
        apply_tint(args.path, no_tint=args.no_tint)
        print(f"wallpaper-tui: applied {args.path} to {args.output}.", file=sys.stderr)
        return

    app = WallpaperTUI(config, state, no_tint=args.no_tint)
    app.run()


if __name__ == "__main__":
    main()
