"""Tests for the chafa ANSI->Rich-Text preview parser (pure) and the
preview-thumbnail cache (tmp-path)."""

from rich.console import Console

from conftest import make_image

ESC = "\x1b"
_CONSOLE = Console()


def _segments(t):
    """Render a Rich Text to its styled Segments (needs a Console)."""
    return list(t.render(_CONSOLE))


# ── ansi_to_textual parser ──────────────────────────────────────────────────


def test_ansi_to_textual_basic_fg_bg(wt):
    ansi = ESC + "[38;2;10;20;30;48;2;40;50;60m" + "A" + ESC + "[0m" + "C"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "AC"
    # The first segment carries the fg/bg colors; the reset segment is default.
    # Assert the parsed RGB triples (not just non-None) so the combined
    # 38;2;...;48;2;... SGR critical path is verified meaningfully and a
    # fg/bg swap or wrong-RGB regression would fail.
    styled = next(s for s in _segments(t) if s.text == "A")
    assert styled.style.color is not None
    fg = styled.style.color.triplet
    assert (fg.red, fg.green, fg.blue) == (10, 20, 30)
    assert styled.style.bgcolor is not None
    bg = styled.style.bgcolor.triplet
    assert (bg.red, bg.green, bg.blue) == (40, 50, 60)


def test_ansi_to_textual_skips_cursor_private_modes(wt):
    """ESC[?25l / ESC[?25h (hide/show cursor) must not emit text or styles."""
    ansi = ESC + "[?25l" + "X" + ESC + "[?25h"
    t = wt.ansi_to_textual(ansi)
    assert t.plain == "X"


def test_ansi_to_textual_reset_clears_style(wt):
    ansi = ESC + "[38;2;1;2;3m" + "A" + ESC + "[0m" + "B"
    t = wt.ansi_to_textual(ansi)
    b = next(s for s in _segments(t) if s.text == "B")
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


def test_ansi_to_textual_does_not_hang_on_lone_esc(wt):
    """A lone/trailing ESC or non-CSI escape must not stall the parser.

    Regression guard: previously the else-branch scanned to the next ESC but
    stopped at ``i`` itself when ``ansi[i]`` was ESC, so ``i`` never advanced
    and the loop hung forever on inputs like ``\\x1b``, ``abc\\x1b``, or
    ``\\x1b(BX`` (a charset designator).
    """
    for ansi in (ESC, "abc" + ESC, ESC + "(BX", "ab" + ESC + ESC + "[0m"):
        t = wt.ansi_to_textual(ansi)
        # Must return (not hang); the ESC byte itself is dropped, never
        # appended as a raw control character.
        assert ESC not in t.plain


# ── cache_previews ──────────────────────────────────────────────────────────


def test_cache_previews_writes_thumbnails(wt, tmp_path):
    folder = tmp_path / "walls"
    folder.mkdir()
    make_image(folder / "a.png", (10, 20, 30))
    make_image(folder / "b.png", (40, 50, 60))
    out = tmp_path / "thumbs"
    r = wt.cache_previews(str(folder), True, out, size=(32, 32))
    assert r["written"] == 2
    pngs = list(out.glob("*.png"))
    assert len(pngs) == 2


def test_cache_previews_skips_unchanged(wt, tmp_path):
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