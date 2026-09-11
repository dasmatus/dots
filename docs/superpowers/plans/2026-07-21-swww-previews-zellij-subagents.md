# awww backend, chafa previews, preview-cache service, zellij-subagents skill implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `swaybg` wallpaper backend with `awww` (animated transitions), add chafa in-TUI wallpaper previews, add a systemd user service that caches preview thumbnails, and add a Claude Code skill that runs each subagent as a live headless `claude -p` session in its own zellij pane.

**Architecture:** All wallpaper logic stays in the single file `nix/home/wallpaper-tui.py` (reuses the config/state split, tint pipeline, and pytest harness in `tests/wallpaper_tui/`). `awww` is the renamed `swww` in this nixpkgs revision. Same CLI, package `pkgs.awww`, binary `awww`, daemon `awww-daemon`, no `init` subcommand. Previews render via the `chafa` CLI → ANSI → a small SGR parser → Rich `Text` shown in a Textual `Static`. The preview cache is a `--cache-previews` mode of the same script, driven by a home-manager systemd user timer. The zellij skill is a project skill + a shell helper driving `zellij action`.

**Tech Stack:** Nix/Home Manager, Python 3 (Textual, Pillow, Rich, which ships with Textual), pytest, `awww`/`awww-daemon`, `chafa`, zellij, headless `claude -p`.

## Global Constraints

- **No inline tests.** Tests live under `tests/wallpaper_tui/` (repo rule). The script is loaded via the `wt` fixture in `tests/wallpaper_tui/conftest.py` (importlib, hyphen-name workaround).
- **Comments:** top-level `//!`/`///`-style only in Rust; in Python, module docstring + `"""docstrings"""` per symbol, inline `//`-equivalent (`#`) only for "magic sorcery", matching the existing file's comment density.
- **No Co-Authored-By / session-link doxxing** in commits or GitLab text.
- **Package names:** `pkgs.awww` (not `pkgs.swww`, which is a rename-warning alias), `pkgs.chafa`. Both verified present in this flake's nixpkgs.
- **awww CLI facts (verified via `awww img --help` in this flake):** no `init` subcommand; `awww img [OPTIONS] <IMAGE>`; `-o,--outputs` comma-separated (omit for all); `--resize no|crop|fit|stretch`; `--fill-color RRGGBBAA` (default `000000ff`); `--transition-type none|simple|fade|left|right|top|bottom|wipe|wave|grow|center|any|outer|random`; `--transition-duration <float>`. Daemon started via `awww-daemon`; `awww query` checks liveness; `awww kill` stops it.
- **chafa CLI facts (verified):** `chafa --format=ansi --symbols=block --size=<cols>x<rows> --color-space=rgb --dither=ordered <img>` emits `ESC[?25l`/`ESC[?25h` (skip), `ESC[0m` (reset), and combined `ESC[38;2;r;g;b;48;2;r;g;bm` SGR runs before each UTF-8 block glyph.
- **Rich API (verified in this flake's textual env):** `from rich.text import Text`, `from rich.style import Style`, `from rich.color import Color`; `Style(color=Color.from_rgb(r,g,b), bgcolor=Color.from_rgb(r,g,b))`; `Text.append(s, style=style)`. Textual `Static.update(rich_text)` renders a Rich `Text`.
- **Test runner:** `just py-test` (pytest in `tests/wallpaper_tui/`). Lint: `just nix-lint`.

---

## File Structure

- **Modify** `nix/home/wallpaper-tui.py`, for the awww backend, chafa preview rendering + `Preview` widget, `cache_previews` + CLI flags. (Single file; all wallpaper logic co-located per existing convention.)
- **Modify** `nix/home/wallpaper-tui.nix`, adding `pkgs.chafa` on PATH; `transitionType`/`transitionDuration`/`cacheInterval` options; systemd user service+timer; description text `swaybg`→`awww`.
- **Modify** `nix/home/default.nix`, swapping `pkgs.swaybg`→`pkgs.awww`; update the comment.
- **Modify** `nix/home/desktop/hyprland.nix`. Add `awww-daemon` to `hyprland.start` exec-once, before `wallpaper-tui --restore`.
- **Modify** `nix/home/random_wp.nix`, updating the error-message string `swaybg/gsettings`→`awww/gsettings`.
- **Create** `tests/wallpaper_tui/test_awww_backend.py`, pure helpers for the awww backend.
- **Create** `tests/wallpaper_tui/test_preview.py`, covering the `ansi_to_textual` parser + `cache_previews`.
- **Create** `.claude/skills/zellij-subagents/SKILL.md`, the skill.
- **Create** `scripts/zellij-subagent.sh`, the pane-spawning helper.

---

### Task 1: awww backend in `apply_wallpaper` (Part 2)

**Files:**
- Modify: `nix/home/wallpaper-tui.py` (replace `apply_wallpaper`, add helpers near it, ~lines 137-158)
- Modify: `nix/home/wallpaper-tui.nix` (options + `declarativeConfig`, ~lines 29-120)
- Modify: `nix/home/default.nix` (~lines 71-74)
- Modify: `nix/home/desktop/hyprland.nix` (~lines 71-81)
- Modify: `nix/home/random_wp.nix` (~line 67)
- Test: `tests/wallpaper_tui/test_awww_backend.py`

**Interfaces:**
- Consumes: existing `groups` shape `{output, path, mode, fill_color}` from `effective_output`/`restore_all`/`action_apply`.
- Produces: `apply_wallpaper(groups, transition_type="grow", transition_duration=1.0) -> list` (called by `restore_all`, `action_apply`, and the non-interactive `--output/--path` path). `config.json` gains `transition_type`/`transition_duration` keys.

- [ ] **Step 1: Write the failing tests**

Create `tests/wallpaper_tui/test_awww_backend.py`:

```python
"""Tests for the awww backend: mode mapping, fill-color normalization, argv
building, and the apply_wallpaper orchestrator (subprocess stubbed)."""

import pytest

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
    assert spawns[0][0] == "awww" and spawns[0][1] == "img"
    assert spawns[1][3] == "HDMI-1"


def test_apply_wallpaper_empty_groups_noop(wt, monkeypatch):
    monkeypatch.setattr(wt.subprocess, "run", lambda *a, **k: True)
    assert wt.apply_wallpaper([]) == []
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just py-test`
Expected: FAIL, `AttributeError: module 'wallpaper_tui' has no attribute 'map_resize'` (and `awww_img_args`, `_normalize_fill_color`).

- [ ] **Step 3: Implement the awww backend in `wallpaper-tui.py`**

Replace the existing `apply_wallpaper` function (lines ~137-158) with:

```python
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
    (setsid-equivalent) and give it a moment. Hyprland.start also exec-onces
    the daemon, so this is a defensive fallback for manual ``--restore`` from a
    terminal. Never raises.
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
```

Update the two callers of `apply_wallpaper` to pass transition config. In `restore_all` (the line `apply_wallpaper(groups)`):

```python
    apply_wallpaper(
        groups,
        transition_type=config.get("transition_type", "grow"),
        transition_duration=config.get("transition_duration", 1.0),
    )
```

In `action_apply` (the `apply_wallpaper([{...}])` call):

```python
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
```

In the non-interactive `--output/--path` path in `main()` (the `apply_wallpaper([{...}])` call):

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just py-test`
Expected: PASS, all 6 new tests green; existing tint tests still green.

- [ ] **Step 5: Wire the Nix options into `config.json`**

In `nix/home/wallpaper-tui.nix`, add to the `options.programs.wallpaper-tui` block (after `currentOutput`):

```nix
    transitionType = lib.mkOption {
      type = lib.types.enum [
        "none" "simple" "fade" "left" "right" "top" "bottom"
        "wipe" "wave" "grow" "center" "any" "outer" "random"
      ];
      default = "grow";
      description = "awww transition effect between wallpapers.";
    };

    transitionDuration = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "awww transition duration in seconds.";
    };
```

Extend `declarativeConfig` (the `builtins.toJSON {...}`) to include:

```nix
    transition_type = cfg.transitionType;
    transition_duration = cfg.transitionDuration;
```

Update the option text: `enable = lib.mkEnableOption "swaybg-based TUI wallpaper changer";` → `"awww-based TUI wallpaper changer";` and the `mode` option description `"swaybg scaling mode."` → `"awww --resize mode (was swaybg scaling mode)."`.

- [ ] **Step 6: Swap the package in `default.nix`**

In `nix/home/default.nix`, replace:

```nix
    # Wayland session tools exec'd by hyprland.nix binds; swaybg is kept for
    # the wallhaven-wallpaper service (random_wp.nix) and the wallpaper-tui
    # module, both of which shell out to it directly.
    swaybg
```

with:

```nix
    # Wayland wallpaper daemon (renamed swww) exec'd by wallpaper-tui via
    # `awww img` for animated transitions; random_wp.nix routes through
    # wallpaper-tui so it inherits awww too. awww-daemon is started at
    # hyprland.start (hyprland.nix).
    awww
```

- [ ] **Step 7: Start `awww-daemon` at hyprland.start**

In `nix/home/desktop/hyprland.nix`, add `awww-daemon` to the `hyprland.start` function **before** `wallpaper-tui --restore`:

```nix
          (lua ''
            function()
              hl.exec_cmd("awww-daemon")
              hl.exec_cmd("waybar")
              hl.exec_cmd("nm-applet --indicator")
              hl.exec_cmd("wallpaper-tui --restore")
            end'')
```

- [ ] **Step 8: Update the `random_wp.nix` error string**

In `nix/home/random_wp.nix`, line ~67:

```nix
    echo "Could not set wallpaper: missing awww/gsettings." >&2
```

- [ ] **Step 9: Lint**

Run: `just nix-lint`
Expected: flake eval passes (no `swww` rename warning now that we use `awww`).

- [ ] **Step 10: Commit**

```bash
git add nix/home/wallpaper-tui.py nix/home/wallpaper-tui.nix nix/home/default.nix nix/home/desktop/hyprland.nix nix/home/random_wp.nix tests/wallpaper_tui/test_awww_backend.py
git commit -m "feat(wallpaper): replace swaybg with awww for animated transitions"
```

---

### Task 2: chafa in-TUI previews (Part 3)

**Files:**
- Modify: `nix/home/wallpaper-tui.py` (add `ansi_to_textual`/`_apply_sgr`/`render_preview_ansi`/`Preview` widget; change `compose` layout; add `p` binding + cursor hooks)
- Modify: `nix/home/wallpaper-tui.nix` (add `pkgs.chafa` to the wrapper PATH)
- Test: `tests/wallpaper_tui/test_preview.py`

**Interfaces:**
- Consumes: `list_wallpapers` (existing); the cached thumbnail path convention from Task 3 (`XDG_CACHE_HOME/wallpaper-tui/thumbs/<sha1>.png`).
- Produces: `ansi_to_textual(ansi) -> rich.text.Text` (pure), `render_preview_ansi(path, cols, rows) -> str` (subprocess), `Preview(Static)` widget used in `WallpaperTUI.compose`.

- [ ] **Step 1: Write the failing tests**

Create `tests/wallpaper_tui/test_preview.py`:

```python
"""Tests for the chafa ANSI→Rich-Text preview parser (pure)."""

ESC = "\x1b"


def test_ansi_to_textual_basic_fg_bg(wt):
    ansi = ESC + "[38;2;10;20;30;48;2;40;50;60m" + "A" + ESC + "[0m" + "C"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "AC"
    # The first segment carries the fg/bg colors; the reset segment is default.
    segs = list(t.render())
    styled = next(s for s in segs if s.text == "A")
    assert styled.style.color is not None
    assert styled.style.bgcolor is not None


def test_ansi_to_textual_skips_cursor_private_modes(wt):
    """ESC[?25l / ESC[?25h (hide/show cursor) must not emit text or styles."""
    ansi = ESC + "[?25l" + "X" + ESC + "[?25h"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "X"


def test_ansi_to_textual_reset_clears_style(wt):
    ansi = ESC + "[38;2;1;2;3m" + "A" + ESC + "[0m" + "B"
    t = wt.ansi_to_textual(ansi)
    segs = list(t.render())
    b = next(s for s in segs if s.text == "B")
    assert b.style.color is None, "reset must clear fg"


def test_ansi_to_textual_handles_multibyte_glyphs(wt):
    """chafa emits UTF-8 block glyphs (e.g. █ = U+2588); they survive as text."""
    ansi = ESC + "[38;2;0;0;0;48;2;255;255;255m" + "█" + ESC + "[0m"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "█"


def test_ansi_to_textual_tolerates_unknown_sgr(wt):
    """A bold (``1``) SGR must not crash; color state is preserved."""
    ansi = ESC + "[1m" + "A" + ESC + "[38;2;5;6;7m" + "B" + ESC + "[0m"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "AB"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just py-test`
Expected: FAIL, `AttributeError: module 'wallpaper_tui' has no attribute 'ansi_to_textual'`.

- [ ] **Step 3: Implement the parser + renderer**

In `nix/home/wallpaper-tui.py`, add a new section after the tint block (before the `WallpaperTUI` class):

```python
# ── Preview (chafa → Rich Text) ────────────────────────────────────────────
# alacritty supports no image protocol, so previews render as chafa unicode-art
# (block symbols) parsed from ANSI into a Rich Text that a Textual Static can
# display. chafa is forced to --format=ansi --symbols=block so output is
# deterministic regardless of whether stdout is a tty.

PREVIEW_CACHE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "wallpaper-tui" / "thumbs"


def _apply_sgr(params, style):
    """Apply one SGR parameter list (``"38;2;r;g;b;48;2;r;g;b"``) to a Rich Style.

    Handles the subset chafa emits: 24-bit fg (``38;2;…``), 24-bit bg
    (``48;2;…``), and ``0`` reset. Unknown params (bold, etc.) are tolerated.
    The current colors are kept so a chafa version change can't break rendering.
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
        # else: unknown SGR, ignore and keep current colors.
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
            final = ansi[j]
            if final == "m":
                style = _apply_sgr(ansi[i + 2:j], style)
            # else: non-SGR CSI (e.g. ?25l/?25h) -> skip, emit no text.
            i = j + 1
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just py-test`
Expected: PASS, 5 new parser tests green.

- [ ] **Step 5: Add the `Preview` widget and wire it into the app**

In `nix/home/wallpaper-tui.py`, add the import near the top (with the other textual imports):

```python
from textual.containers import Horizontal
```

Add the `Preview` widget (before the `WallpaperTUI` class):

```python
class Preview(Static):
    """Chafa-rendered unicode-art preview of the currently-selected wallpaper."""

    PREVIEW_COLS = 48
    PREVIEW_ROWS = 20

    def show_path(self, path):
        """Render `path` (cached thumbnail preferred) into this widget."""
        if not path or not Path(path).exists():
            self.update("[preview unavailable]")
            return
        ansi = render_preview_ansi(_thumb_for(path), self.PREVIEW_COLS, self.PREVIEW_ROWS)
        if not ansi:
            self.update("[preview unavailable]")
            return
        self.update(ansi_to_textual(ansi))
```

In `WallpaperTUI`, add a `p` binding and a per-path memo cache. Update `BINDINGS`:

```python
        Binding("p", "toggle_preview", "Preview"),
```

In `__init__`, after `self.wallpapers = list_wallpapers(...)`, add:

```python
        self._preview_cache = {}
        self._show_preview = True
```

Replace `compose` with a horizontal layout that includes the preview:

```python
    def compose(self) -> ComposeResult:
        yield Header()
        if self.wallpapers:
            if self._show_preview:
                yield Horizontal(
                    ListView(
                        *[ListItem(Label(p.name), name=str(p)) for p in self.wallpapers],
                        id="list",
                    ),
                    Preview(id="preview"),
                )
            else:
                yield ListView(
                    *[ListItem(Label(p.name), name=str(p)) for p in self.wallpapers],
                    id="list",
                )
        else:
            yield Label(
                f"No wallpapers found in: {self.config.get('wallpaper_folder', '?')}",
                id="empty",
            )
        yield Static(self.info_text(), id="info")
        yield Footer()
```

Add a helper that (re)renders the preview for the current selection, and call it on launch and after every cursor move. Add to the class:

```python
    def _refresh_preview(self):
        if not self._show_preview:
            return
        try:
            preview = self.query_one("#preview", Preview)
        except Exception:
            return
        path = self.selected_path()
        if not path:
            return
        if path not in self._preview_cache:
            self._preview_cache[path] = None  # placeholder; filled below
            self._preview_cache[path] = render_preview_ansi(
                _thumb_for(path), Preview.PREVIEW_COLS, Preview.PREVIEW_ROWS)
        ansi = self._preview_cache[path]
        if ansi:
            preview.update(ansi_to_textual(ansi))
        else:
            preview.show_path(path)
```

Hook cursor moves: in `action_cursor_up` and `action_cursor_down`, append `self._refresh_preview()` at the end of each. In `on_list_view_selected`, the existing `self.action_apply()` stays; also call `self._refresh_preview()` first. After the app mounts, refresh once. Add:

```python
    def on_mount(self) -> None:
        self._refresh_preview()
```

Add the toggle action:

```python
    def action_toggle_preview(self):
        self._show_preview = not self._show_preview
        # Re-compose to add/remove the preview pane.
        self.call_after_refresh(self.refresh_layout)

    def refresh_layout(self):
        self.mutate_repetitive_widgets()
        # Simplest reliable toggle: relaunch the compose tree.
        for child in list(self.children):
            child.remove()
        self.compose()
```

> Note: the `refresh_layout` above is a sketch. If Textual's API makes full re-compose awkward, the minimal viable implementation is to always mount the `Horizontal(list, Preview)` and just `display = False/True` the `#preview` widget in `action_toggle_preview` (no re-compose). Prefer that simpler form:

```python
    def action_toggle_preview(self):
        self._show_preview = not self._show_preview
        try:
            self.query_one("#preview", Preview).display = self._show_preview
        except Exception:
            pass
```

…and always mount the `Horizontal(ListView, Preview)` in `compose` (drop the `if self._show_preview` branch). Use this simpler form; remove `refresh_layout`.

- [ ] **Step 6: Add `pkgs.chafa` to the wrapper PATH in `wallpaper-tui.nix`**

In `nix/home/wallpaper-tui.nix`, the `wallpaper-tui` wrapper `writeShellScriptBin` block needs chafa added to the environment so the `chafa` subprocess resolves:

```nix
  wallpaper-tui =
    pkgs.writeShellScriptBin "wallpaper-tui"
      ''
        export WALLPAPER_TUI_KVANTUM_BASE="''${WALLPAPER_TUI_KVANTUM_BASE:-${pkgs.catppuccin-kvantum}/share/Kvantum/catppuccin-frappe-blue}"
        export WALLPAPER_TUI_ICON_BASE="''${WALLPAPER_TUI_ICON_BASE:-${pkgs.morewaita-icon-theme}/share/icons/MoreWaita}"
        export PATH="${lib.makeBinPath [ pkgs.chafa ]}:$PATH"
        exec ${lib.getExe wallpaper-tui-py} "$@"
      '';
```

- [ ] **Step 7: Run tests + lint**

Run: `just py-test && just nix-lint`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add nix/home/wallpaper-tui.py nix/home/wallpaper-tui.nix tests/wallpaper_tui/test_preview.py
git commit -m "feat(wallpaper-tui): chafa unicode-art wallpaper previews"
```

---

### Task 3: preview-cache systemd user service (Part 4)

**Files:**
- Modify: `nix/home/wallpaper-tui.py` (add `cache_previews` + `--cache-previews`/`--preview-size` CLI)
- Modify: `nix/home/wallpaper-tui.nix` (add `cacheInterval` option + `systemd.user` service/timer)
- Test: `tests/wallpaper_tui/test_preview.py` (append `cache_previews` tests)

**Interfaces:**
- Consumes: `list_wallpapers` (existing), `PREVIEW_CACHE` (from Task 2).
- Produces: `cache_previews(folder, recursive, out_dir, size=(320,200)) -> dict` (counts); the `--cache-previews` CLI mode writes to `PREVIEW_CACHE`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/wallpaper_tui/test_preview.py`:

```python
def test_cache_previews_writes_thumbnails(wt, tmp_path, monkeypatch):
    folder = tmp_path / "walls"
    folder.mkdir()
    make_image(folder / "a.png", (10, 20, 30))
    make_image(folder / "b.png", (40, 50, 60))
    out = tmp_path / "thumbs"
    r = wt.cache_previews(str(folder), True, out, size=(32, 32))
    assert r["written"] == 2
    pngs = list(out.glob("*.png"))
    assert len(pngs) == 2


def test_cache_previews_skips_unchanged(wt, tmp_path, monkeypatch):
    folder = tmp_path / "walls"
    folder.mkdir()
    make_image(folder / "a.png", (10, 20, 30))
    out = tmp_path / "thumbs"
    wt.cache_previews(str(folder), True, out, size=(32, 32))
    # Second run: same mtime -> skip.
    r = wt.cache_previews(str(folder), True, out, size=(32, 32))
    assert r["written"] == 0
    assert r["skipped"] == 1


def test_cache_previews_nonexistent_folder(wt, tmp_path):
    r = wt.cache_previews(str(tmp_path / "nope"), True, tmp_path / "thumbs")
    assert r["written"] == 0
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just py-test`
Expected: FAIL, `AttributeError: module 'wallpaper_tui' has no attribute 'cache_previews'`.

- [ ] **Step 3: Implement `cache_previews` + CLI**

In `nix/home/wallpaper-tui.py`, add after `_thumb_for`:

```python
def cache_previews(folder, recursive, out_dir, size=(320, 200)):
    """Generate/refresh downsampled PNG thumbnails for every wallpaper.

    Idempotent + mtime-skipped: a thumbnail is regenerated only when the
    source's mtime is newer than the cached one (or the cache is missing).
    Returns ``{"written": n, "skipped": m}``. Unreadable images are skipped
    with a stderr warning and never crash the run.
    """
    import hashlib
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
        try:
            with Image.open(p) as im:
                im = im.convert("RGB")
                im.thumbnail(size)
                im.save(thumb, "PNG")
            written += 1
        except Exception as e:  # noqa: BLE001, best-effort
            print(f"wallpaper-tui: cache skip {p}: {e}", file=sys.stderr)
    return {"written": written, "skipped": skipped}
```

In `main()`, add the CLI flags next to the existing `argparse` lines:

```python
    parser.add_argument("--cache-previews", action="store_true", help="regenerate the wallpaper thumbnail cache and exit")
    parser.add_argument("--preview-size", default="320x200", help="thumbnail size WxH for --cache-previews")
```

Add the handler in `main()` after the `--restore` block and before the `args.path` block:

```python
    if args.cache_previews:
        w, h = (int(x) for x in args.preview_size.lower().split("x"))
        r = cache_previews(config.get("wallpaper_folder", ""),
                           config.get("recursive", True), PREVIEW_CACHE, size=(w, h))
        print(f"wallpaper-tui: cached {r['written']} new, skipped {r['skipped']}.", file=sys.stderr)
        return
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just py-test`
Expected: PASS, 3 new cache tests green.

- [ ] **Step 5: Add the `cacheInterval` option + systemd service/timer in `wallpaper-tui.nix`**

In `options.programs.wallpaper-tui`, add:

```nix
    cacheInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar for the preview-cache timer.";
    };
```

In the `config = lib.mkIf cfg.enable { ... }` block, add (after `home.packages = [ wallpaper-tui ];`):

```nix
    systemd.user.services.wallpaper-preview-cache = {
      Unit = {
        Description = "Cache wallpaper-tui preview thumbnails";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe wallpaper-tui} --cache-previews";
      };
    };

    systemd.user.timers.wallpaper-preview-cache = {
      Unit.Description = "Periodic wallpaper-tui preview cache refresh";
      Timer = {
        OnCalendar = cfg.cacheInterval;
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
```

- [ ] **Step 6: Lint**

Run: `just nix-lint`
Expected: flake eval passes; the new systemd units evaluate.

- [ ] **Step 7: Commit**

```bash
git add nix/home/wallpaper-tui.py nix/home/wallpaper-tui.nix tests/wallpaper_tui/test_preview.py
git commit -m "feat(wallpaper-tui): systemd user preview-cache service"
```

---

### Task 4: zellij-subagents skill + helper (Part 1)

**Files:**
- Create: `.claude/skills/zellij-subagents/SKILL.md`
- Create: `scripts/zellij-subagent.sh`

**Interfaces:**
- Consumes: a running zellij session (the user's `main` session, `attach_to_session = true` in `nix/home/shell/zellij.nix`); the `claude` CLI on PATH.
- Produces: one zellij tab `subagents` with one pane per task; each pane runs `claude -p "<prompt>"` writing JSON to `/tmp/zellij-subagents/<n>.json` and a `<n>.done` sentinel when finished.

- [ ] **Step 1: Create the helper script**

Create `scripts/zellij-subagent.sh`:

```bash
#!/usr/bin/env bash
# Open a new zellij pane running a headless `claude -p` session, writing its
# JSON result to a file and a `.done` sentinel on completion. Used by the
# zellij-subagents skill so each subagent task gets its own watchable pane.
#
# Usage: zellij-subagent.sh <pane-name> <result-json> <prompt-file>
#
# Requires: a running zellij session (the caller's shell inherits $ZELLIJ);
# zellij >= 0.40 for `zellij action new-pane --name`.
set -euo pipefail

name="${1:?usage: zellij-subagent.sh <pane-name> <result-json> <prompt-file>}"
result="${2:?missing result-json path}"
prompt="${3:?missing prompt-file path}"

mkdir -p "$(dirname "$result")"

# zellij action targets the current session and returns immediately (non-
# blocking), so the orchestrator can open several panes in sequence. The pane
# runs claude headless; stdout (the JSON result) is redirected to $result, and
# a .done sentinel is touched when claude exits so the orchestrator can poll.
# NB: omit --close-on-exit/-c (a value-less boolean meaning close-on-exit=true
# on zellij 0.44.3; `--close-on-exit false` is a hard parse error). The default
# (flag absent) keeps the pane open. This is the intended watchable-subagent
# behavior.
zellij action new-pane \
  --name "$name" \
  -- bash -c "claude -p \"\$(cat '$prompt')\" > '$result'; touch '$result.done'"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/zellij-subagent.sh`
Expected: no output; `ls -l scripts/zellij-subagent.sh` shows the `x` bits.

- [ ] **Step 3: Create the skill**

Create `.claude/skills/zellij-subagents/SKILL.md`:

```markdown
---
name: zellij-subagents
description: Use when dispatching multiple subagent tasks and you want each running as a live, watchable headless `claude -p` session in its own zellij pane (one tab, one pane per subagent). Falls back to the normal in-process Agent tool when not inside a zellij session.
---

# Zellij subagent panes

Run each subagent task as a **separate headless `claude -p` session** in its own
zellij pane, so the user can watch every agent work live. One new tab holds all
the panes for the current orchestration.

## When to use

- You are about to dispatch **multiple** subagent tasks (research, parallel
  implementation, multi-file review), and
- The user is running inside a zellij session (`$ZELLIJ` is set), and
- The user wants live visibility into each agent.

If `$ZELLIJ` is unset, **do not** use this skill. Fall back to the normal
in-process `Agent` tool. Headless `claude -p` panes only make sense when there
is a zellij session to attach panes to.

## Procedure

1. **Decompose** the work into N independent subagent tasks. Write each task's
   prompt to its own file under `/tmp/zellij-subagents/`:

   ```bash
   mkdir -p /tmp/zellij-subagents
   printf '%s' '<task-1 prompt>' > /tmp/zellij-subagents/1.prompt
   printf '%s' '<task-2 prompt>' > /tmp/zellij-subagents/2.prompt
   # ...
   ```

2. **Open a tab** for the orchestration:

   ```bash
   zellij action new-tab --name subagents
   ```

3. **Open one pane per task** via the helper (non-blocking; returns immediately):

   ```bash
   scripts/zellij-subagent.sh agent-1 /tmp/zellij-subagents/1.json /tmp/zellij-subagents/1.prompt
   scripts/zellij-subagent.sh agent-2 /tmp/zellij-subagents/2.json /tmp/zellij-subagents/2.prompt
   # ...
   ```

   Each pane runs `claude -p "$(cat <prompt>)" > <result>.json; touch <result>.done`.

4. **Wait for completion** by polling the `.done` sentinels (background bash):

   ```bash
   for i in 1 2; do
     while [ ! -f "/tmp/zellij-subagents/$i.json.done" ]; do sleep 2; done
   done
   ```

5. **Read the JSON results** and synthesize an answer from all of them. The
   files contain whatever the headless `claude -p` sessions wrote to stdout.

6. **Clean up** the temp files when done: `rm -f /tmp/zellij-subagents/*`.

## Notes

- zellij CLI flags evolve; `zellij action new-pane --name` and
  `zellij action new-tab --name` are stable in zellij 0.40+.
  `--close-on-exit`/`-c` is a **boolean** flag (no value) meaning
  close-on-exit=true. Never pass `--close-on-exit false`; omit it to keep
  panes open. If a flag is rejected, run `zellij action new-pane --help` and
  adjust.
- Headless `claude -p` uses the user's normal auth/plan; each pane is a real
  billed session. Prefer fewer, well-scoped panes over many tiny ones.
- The helper writes results to `/tmp` (not the repo) so nothing pollutes the
  working tree.
```

- [ ] **Step 4: Sanity-check the helper syntax**

Run: `bash -n scripts/zellij-subagent.sh && echo OK`
Expected: `OK` (syntax check passes; no zellij session needed).

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/zellij-subagents/SKILL.md scripts/zellij-subagent.sh
git commit -m "feat(skills): zellij-subagents skill — live headless claude per pane"
```

---

### Task 5: Lint, test, and smoke

**Files:** none (verification only).

- [ ] **Step 1: Full Python test suite**

Run: `just py-test`
Expected: all tests in `tests/wallpaper_tui/` pass (existing tint + new awww/preview/cache).

- [ ] **Step 2: Nix lint**

Run: `just nix-lint`
Expected: flake eval + fmt/clippy/test pass; no `swww` rename warning.

- [ ] **Step 3: Confirm no stray `swaybg` references remain**

Run: `grep -rn swaybg nix/ | grep -v '^nix/home/default.nix:#'`
Expected: no matches (the only remaining `swaybg` mention is the historical comment in `default.nix` explaining the awww swap, which is fine, or remove it if it reads confusingly).

- [ ] **Step 4: Build the home config (smoke)**

Run: `nix build .#homeConfigurations.matus.activationPackage --no-link 2>&1 | tail -20` (adjust the attr name to the actual one in `flake.nix`, checking with `nix flake show .#` first)
Expected: builds; the new `awww`/`chafa` deps and systemd units resolve.

- [ ] **Step 5: Commit any final fixes (if needed)**

Only if Step 3/4 surfaced changes:

```bash
git add -A
git commit -m "fix(wallpaper): final lint/smoke corrections"
```

---

## Self-Review (author's checklist, run after writing)

- **Spec coverage:** Part 2 (awww) → Task 1. Part 3 (chafa previews) → Task 2. Part 4 (cache service) → Task 3. Part 1 (zellij skill) → Task 4. Lint/smoke → Task 5. All four parts covered.
- **Placeholder scan:** the `refresh_layout` sketch in Task 2 Step 5 is explicitly called out and replaced with the simpler `display` toggle. The engineer is told to use the simpler form and drop `refresh_layout`. No TBD/TODO elsewhere.
- **Type consistency:** `apply_wallpaper(groups, transition_type, transition_duration) -> list` matches across Task 1's three callers. `ansi_to_textual`/`render_preview_ansi`/`_thumb_for`/`Preview` names match between Task 2 steps and Task 3's `cache_previews` (which uses `PREVIEW_CACHE` + `list_wallpapers`). `cache_previews(folder, recursive, out_dir, size=...)` signature matches the tests and the CLI handler.