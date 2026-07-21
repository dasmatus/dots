# swww backend, chafa previews, preview-cache service, zellij-subagents skill

**Date:** 2026-07-21
**Status:** Approved-by-directive (goal hook: "lgtm")
**Scope:** Four related changes to the dots wallpaper stack and the Claude Code
workflow layer:

1. Replace `swaybg` with `swww` as the wallpaper backend so wallpaper changes
   get animated transitions.
2. Add in-TUI wallpaper previews to `wallpaper-tui` (chafa unicode-art).
3. Add a systemd user service that periodically caches wallpaper preview
   thumbnails.
4. Add a Claude Code skill that runs each dispatched subagent as a live,
   watchable headless `claude -p` session in its own zellij pane.

## Decisions (from brainstorming)

- **Wallpaper daemon:** `swww` — but in this nixpkgs revision `swww` has been
  **renamed to `awww`** (same project, same CLI; `pkgs.swww` is now an alias
  that emits a rename warning, the package is `pkgs.awww`, binary `awww`,
  daemon `awww-daemon`). Premise check: hyprpaper does **not** support animated
  transitions (it is the Hypr team's static, IPC-controlled daemon). The
  cross-fade feature in the Hypr ecosystem lives in hyprlock, not hyprpaper.
  `awww`/`swww` is the Wayland daemon with real transitions (`--transition-type`
  `none|simple|fade|left|right|top|bottom|wipe|wave|grow|center|any|outer|random`,
  `--transition-duration`, animated GIF support). Verified via the Hyprland
  wiki "Wallpapers" page, the swww README, and `awww img --help` in this flake.
- **Preview rendering:** chafa unicode-art rendered **inside** the Textual TUI.
  Premise check: Alacritty supports no image protocol (no Kitty graphics, no
  Sixel, no iTerm2 inline — conservative maintainer stance), so true inline
  images are impossible in the user's terminal. chafa forced to
  `--format=ansi --symbols=block` produces deterministic ANSI color escapes we
  parse into Textual `Text`. Verified via the Hyprland wiki, swww man page,
  and terminal-emulator comparison articles (2026).
- **Cache target:** a thumbnail/preview cache. A systemd user timer periodically
  scans the wallpaper folder and (re)generates downsampled PNG thumbnails under
  `XDG_CACHE_HOME/wallpaper-tui/thumbs/`; the TUI reads these for instant chafa
  rendering instead of decoding full-res images on every launch.
- **Zellij skill:** each pane runs a separate headless `claude -p "<task>"`
  process (a real subagent CLI session) so the user can watch every agent work
  live. Claude orchestrates by spawning these via `zellij action new-pane`.

## Architecture

All wallpaper logic stays in the single file `nix/home/wallpaper-tui.py`
(reuses the config/state split, the tint pipeline, and the pytest harness in
`tests/wallpaper_tui/`). Targeted additions only — no new modules.

### Part 2 — swww backend

`apply_wallpaper(groups)` changes from "kill + respawn a detached swaybg" to
"ensure the awww daemon is up, then send one `awww img` IPC command per output":

```
apply_wallpaper(groups, transition_type, transition_duration):
  ensure_awww_daemon()            # awww query; spawn awww-daemon (setsid) if down
  for g in groups:
    awww img [-o <g.output>] <g.path>
        --resize <map(g.mode)> --fill-color <norm(g.fill_color)>
        --transition-type <T> --transition-duration <D>
```

`awww` has **no `init` subcommand** (unlike swww), so the daemon is started
explicitly: `awww-daemon` is added to the `hyprland.start` exec-once block
(before `wallpaper-tui --restore`), and `ensure_awww_daemon()` is a defensive
fallback (`awww query` checks; if it fails, spawn `awww-daemon` detached via
`start_new_session=True` and sleep briefly) so manual `wallpaper-tui --restore`
from a terminal still works. The `pkill swaybg` + per-apply detach logic is
removed — the persistent `awww-daemon` owns the wallpaper, so there is no race
and no respawn per apply.

**Mode mapping** (swaybg `-m` → awww `--resize`):

| swaybg mode | awww `--resize` | note |
|-------------|-----------------|------|
| `fill`      | `crop`          | fill screen, crop overflow |
| `stretch`   | `stretch`       | awww supports stretch (distort) directly |
| `fit`       | `fit`           | preserve aspect, letterbox with `--fill-color` |
| `center`    | `no`            | no resize, centered, padded with `--fill-color` |
| `tile`      | `no`            | **awww has no tile**; degrades to centered (documented) |

`fillColor` → `--fill-color` **normalized** to bare `RRGGBBAA`: strip `#`,
append `ff` if 6-digit (awww's default is `000000ff`). For the `*`/all-outputs
case, `-o` is omitted entirely (awww has no `*`; empty `--outputs` = all).

**New Nix options** in `wallpaper-tui.nix` (threaded into `config.json` and
read by `apply_wallpaper`):

- `transitionType` — enum `none, simple, fade, left, right, top, bottom, wipe,
  wave, grow, center, any, outer, random`, default `grow`.
- `transitionDuration` — `float`, default `1.0`.

`--restore` and the tint pipeline are unchanged. The existing
`wallpaper-tui --restore` at `hyprland.start` now finds `awww-daemon` already
running (started just before it). The GNOME `gsettings` fallback in
`random_wp.nix` is untouched (awww is Hyprland-only).

### Part 3 — chafa previews

A fixed-width preview pane beside the list, rendered from the cached thumbnail
via the `chafa` CLI, with an ANSI→Textual parser so it displays natively
(Textual widgets do not render raw ANSI escapes).

New pure / pure-ish functions in `wallpaper-tui.py`:

1. **`render_preview_ansi(thumb_path, cols, rows) -> str`**
   Subprocess `chafa --format=ansi --symbols=block --size={cols}x{rows}
   --color-space=rgb24 --dither=ordered <thumb>`, return stdout. Flags are
   forced so output is deterministic regardless of whether stdout is a tty
   (chafa otherwise auto-detects and drops color in a pipe).

2. **`ansi_to_textual(ansi) -> textual.text.Text`**  *(pure, unit-tested)*
   Parse `ESC[38;2;r;g;bm` (fg), `ESC[48;2;r;g;bm` (bg), and `ESC[0m` (reset)
   SGR runs into Textual `Text` segments with `Style(color=..., bgcolor=...)`.
   Non-SGR bytes are appended as plain text. This is the core of the feature
   and the main unit-test target.

3. **`Preview(Static)` widget**
   On selection change: pick the cached thumbnail (part 4) if present, else fall
   back to running chafa on the full-res image. Memoize the rendered `Text` per
   path in-process (dict on the app). `update()` the widget.

Layout: `Horizontal(ListView(id="list"), Preview(id="preview"))`, preview pane
~50 cols × 20 rows. Updates fire on `j`/`k` cursor moves and on launch. A `p`
binding toggles the pane for small terminals.

`pkgs.chafa` is added to the wrapper's PATH so the subprocess resolves.

### Part 4 — preview-cache service

Extend `wallpaper-tui` with a `--cache-previews` mode (reuses `list_wallpapers`
+ Pillow), driven by a home-manager `systemd.user` service+timer.

4. **`cache_previews(folder, recursive, out_dir, size=(320,200))`**
   Scan with `list_wallpapers`; for each wallpaper whose mtime is newer than its
   cached thumbnail (or missing), Pillow `thumbnail()` → write
   `XDG_CACHE_HOME/wallpaper-tui/thumbs/<sha1(path+mtime)>.png`. Idempotent,
   mtime-skipped. *(Pure-ish, unit-testable with `tmp_path`.)*

CLI: `--cache-previews` invokes it (plus `--preview-size WxH`); `--restore` /
TUI paths unchanged.

`wallpaper-tui.nix` `config` block adds:

- `systemd.user.services.wallpaper-preview-cache` — oneshot,
  `PartOf = [graphical-session.target]`, `After = [graphical-session.target]`,
  `ExecStart = wallpaper-tui --cache-previews`.
- `systemd.user.timers.wallpaper-preview-cache` — `OnCalendar` from
  `cfg.cacheInterval` (default `daily`), `Persistent = true`,
  `WantedBy = [timers.target]`.

New option `cfg.cacheInterval` (str, default `"daily"`) so the cadence is
tunable without editing the module.

The TUI reads these thumbnails for instant chafa rendering (ties parts 3+4); on
a cache miss it falls back to full-res so first-run still works.

### Part 1 — zellij-subagents skill

A project skill `.claude/skills/zellij-subagents/SKILL.md` plus a helper
`scripts/zellij-subagent.sh`, driving `zellij action` to open one tab with one
pane per headless `claude -p` session.

**Skill** (`description` triggers when dispatching multiple subagent tasks and
wanting live visibility): instructs Claude to:

1. Write each subagent task to a prompt file under `/tmp/zellij-subagents/`.
2. `zellij action new-tab --name subagents`.
3. For each task, run the helper to open a pane running `claude -p "<prompt>"`
   whose JSON result is redirected to `/tmp/zellij-subagents/<n>.json` with a
   `.done` sentinel.
4. Wait on the `.done` files (background bash `wait`/poll).
5. Read the JSON results and synthesize.

**Helper** `scripts/zellij-subagent.sh <name> <result-json> <prompt-file>`:

```
zellij action new-pane --name "<name>" -- \
  bash -c 'claude -p "$(cat "<prompt-file>")" > "<result-json>"; touch "<result-json>.done"'
```

Uses `zellij action` (non-blocking; targets the current session — works because
Claude's shell inherits the user's zellij session env, `$ZELLIJ`). The pane is
left open after `claude` exits (the default) so the user can watch each
subagent; do **not** pass `--close-on-exit`/`-c`, which on zellij 0.44.3 is a
value-less boolean flag meaning close-on-exit=true (and `--close-on-exit false`
is a hard parse error). The skill notes that zellij CLI flags evolve and the
helper should be verified against the installed version
(`zellij action new-pane`/`new-tab` are stable in 0.40+).

Co-located in the repo (version-controlled with the dots); the user can symlink
to `~/.claude/skills/` for global use.

## Nix changes summary

- **`nix/home/wallpaper-tui.py`**: awww-backed `apply_wallpaper` (+ mode
  mapping, fill-color normalization, `ensure_awww_daemon`); `render_preview_ansi`,
  `ansi_to_textual`, `Preview` widget; `cache_previews` +
  `--cache-previews`/`--preview-size` CLI.
- **`nix/home/wallpaper-tui.nix`**: `pkgs.chafa` on PATH; `transitionType` /
  `transitionDuration` / `cacheInterval` options; `systemd.user` service+timer
  for `wallpaper-preview-cache`; descriptions `swaybg` → `awww`.
- **`nix/home/default.nix`**: `pkgs.swaybg` → `pkgs.awww` in `home.packages`;
  comment updated.
- **`nix/home/random_wp.nix`**: no change (already routes through
  `wallpaper-tui --output '*' <path>`; the error message string `swaybg/gsettings`
  → `awww/gsettings`).
- **`nix/home/hyprland.nix`**: add `awww-daemon` to the `hyprland.start`
  exec-once block, before `wallpaper-tui --restore`.

## Testing (`tests/wallpaper_tui/`, pytest, pure functions)

Per repo rule, tests live under `tests/`, no inline tests.

- `test_apply_wallpaper_swww.py`: `apply_wallpaper` builds the expected
  `swww init` + per-output `swww img` argv (mode mapping: fill→crop,
  fit→fit, center→no, tile→no; fill-color passed through; transition flags
  from config). Subprocess is stubbed.
- `test_ansi_to_textual.py`: a hand-crafted chafa-style ANSI string
  (`\x1b[38;2;10;20;30mA\x1b[48;2;40;50;60mB\x1b[0mC`) parses to a Textual
  `Text` with the right per-segment colors; reset returns to default; unknown
  SGR params are tolerated.
- `test_cache_previews.py`: `tmp_path` fixture with two fake image files;
  `cache_previews` writes thumbnails, skips unchanged files on a second run
  (mtime check), and is idempotent.
- Existing `test_extract_accent.py` / `test_tint_writers.py` stay green.
- `just py-test` runs the suite; optionally fold into `just nix-lint`.

## Error handling & CLI

- `awww-daemon` not running / `awww` missing → `ensure_awww_daemon` tries to
  spawn it; if that fails, fall back to a stderr warning, do not crash. The
  GNOME `gsettings` path in `random_wp.nix` covers non-Hyprland sessions.
- chafa missing / subprocess error → preview pane shows `[preview unavailable]`
  and the rest of the TUI keeps working.
- Unreadable image in `cache_previews` → skip that file with a stderr warning,
  continue.
- `--no-tint` and `--restore` semantics unchanged.

## Risks

- **`tile` mode is lost** on swww (no tile support). Accepted; degrades to
  centered. Flagged to the user — if tile matters, special-case it later.
- **chafa packaging:** `pkgs.chafa` (the CLI) is in nixpkgs; the Python binding
  `chafa.py` may not be. We use the CLI + our own ANSI parser to avoid the
  binding dependency entirely.
- **zellij flag drift:** `zellij action` subcommands evolve; the helper
  documents the minimum-version assumption and is easy to fix in place.
- **ANSI parser edge cases:** chafa emits a bounded subset of SGR (24-bit fg/bg
  + reset). The parser handles exactly that and tolerates the rest by passing
  unknown bytes through as text, so a chafa version change that adds e.g.
  bold/italic won't break rendering (just style fidelity).