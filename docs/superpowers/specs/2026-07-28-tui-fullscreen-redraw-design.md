# TUI fullscreen redraw — design

**Date:** 2026-07-28
**Status:** Implemented
**Apps:** `rust/installer-tui`, `rust/wallpaper-tui`, `rust/hyprmon`

## Problem

All three TUI apps render through the `abstracttui` engine, which uses a
**damage-tracked diff presenter**: each frame it re-emits only the cells whose
bytes changed since the previous frame, wrapped in DEC-2026 synchronized
output, inside an alternate screen buffer with the cursor hidden. This is
sophisticated and byte-efficient, but it has one failure mode: the damage
contract trusts the terminal to keep every cell the engine ever painted. When
that assumption breaks **externally** — a stray `printf '\033c'`, Cmd+K in
Terminal.app, an emulator glitch, scrollback bleed, a tmux pane switch with no
focus redraw — model-side damage cannot heal the screen, because a repaint that
produces byte-identical cells emits **nothing** (the diff correctly suppresses
equal cells). The loss is permanent: stale artifacts persist until something
else damages those cells.

The user observed this as "stale artifacts / desync" and asked for Claude-Code
-style fullscreen rendering: **rewrite the console properly on each draw** so
the screen always converges to the correct state.

## Key engine facts discovered

- `abstracttui::app::request_full_redraw()` is the engine's own self-healing
  verb ("the Ctrl+L class"). It poisons the previous-frame cell model,
  invalidates the presenter (virtual cursor + pen), damages every layer, and
  re-places protocol images, so the next frame re-emits **every** cell — a
  true full rewrite on that draw, still wrapped in DEC-2026 sync (tear-free).
- `abstracttui::app::set_redraw_on_focus_gained(true)` triggers the same
  resync on every DEC-1004 FocusGained. Default OFF. The driver already
  resyncs automatically on resize and suspend/resume.
- `Turn::idle` is `events == 0` and **independent of whether a frame
  rendered**. So forcing a full redraw every turn does **not** cause a busy
  spin — an idle turn with no input still reports `idle = true`, and the
  existing `if turn.idle { wait_until(poll) }` pace still blocks.
- The engine enters alt-screen, hides the cursor, enables DEC-1004 focus
  events, and uses DEC-2026 sync output by default (`EnterOptions::default()`).
- `abstracttui::term::emergency_restore()` is public. The `EMERGENCY` slot is
  armed during `term.enter()` (called by `Driver::new`) with the full
  `leave_bytes()` + termios, and accumulates extra restores (kitty-keyboard
  pop, cursor-style, title, pixel-mouse) as features are armed. A panic hook
  that calls it restores the terminal on crash. `App::run` installs this hook
  internally (private `install_panic_hook`); the custom `Driver` loops do not.

## Approach chosen

**C — full-frame rewrite every draw**, applied uniformly to all three apps.

At the top of every loop iteration, immediately before `Driver::turn()`, call
`abstracttui::app::request_full_redraw()`. Every rendered frame becomes a
complete console rewrite using the engine's existing compositor and sync
machinery (not bypassing it). Any desync self-heals on the very next draw.

### Why C over the alternatives

- **A (event-driven: focus-gained + Ctrl+L)** is cheapest but does not
  auto-heal on bare tty1, where the Linux VT does not emit DEC-1004 focus
  sequences. The installer's target is tty1, so A alone is insufficient there.
- **B (periodic ~1 s resync)** is the byte-frugal middle ground, but the user
  explicitly chose C (every frame) for uniform "always converges" behavior.
- **C** is the most expensive but the most robust: zero-latency convergence,
  no dependence on terminal focus reporting.

### Accepted cost

- Text apps (`installer-tui`, `hyprmon`): ~screen-size bytes per draw, at the
  idle-poll cadence (~20 fps with the default 50 ms idle interval) and per
  input event when active. Negligible locally, modest over SSH.
- `wallpaper-tui`: every draw also re-uploads the preview image — kitty:
  `release` + full base64 PNG re-transmit; iTerm2/sixel: re-emit pixels. At
  ~20 fps idle this is ~MB/s over SSH. **Accepted per the explicit decision**
  ("C everywhere, accept image re-upload"). The `DOTS_TUI_IDLE_MS` tunable is
  the escape valve for slow links.

## Changes per app

### `installer-tui` / `wallpaper-tui` (custom `Driver` loops)

One-line addition at the top of the existing loop:

```rust
abstracttui::app::request_full_redraw();
```

before `driver.turn(&mut engine, &mut term)?;`. No structural change — the
existing `if turn.idle { driver.wait_until(... poll) }` pace still blocks on
idle (the `Turn::idle` insight above). The worker-drain / Fx-tick / dispatch
logic is unchanged.

Both apps also gain:

- `install_panic_hook()` — installs a `std::panic::set_hook` that calls
  `abstracttui::term::emergency_restore()` then chains the previous hook, so a
  crash in the loop never leaves the controlling tty in raw mode / alt screen
  / hidden cursor. Called once after `Driver::new` arms the EMERGENCY slot.
- `idle_interval()` — reads `DOTS_TUI_IDLE_MS` (default 50 ms, clamped ≥ 1) and
  returns the idle poll `Duration`. The idle interval doubles as the cadence
  at which an idle screen is fully repainted.

### `hyprmon` (was `App::run`)

`hyprmon` used the engine's built-in `App::run()`, which has no per-turn hook
and owns the terminal + panic hook internally. Replaced `app.run()` in
`tui::run` with an explicit `Driver` loop matching the other two apps:

```rust
let mut term = UnixTerminal::new().map_err(anyhow::Error::msg)?;
let mut driver = Driver::new(&mut app, &mut term, RunConfig::default())
    .map_err(anyhow::Error::msg)?;
install_panic_hook();
let poll = idle_interval();
let result = loop {
    abstracttui::app::request_full_redraw();
    let turn = driver.turn(&mut app, &mut term).map_err(anyhow::Error::msg)?;
    if turn.quit { break Ok(()); }
    if turn.idle {
        if let Err(e) = driver.wait_until(&mut term, Instant::now() + poll) {
            break Err(anyhow::Error::msg(e));
        }
    }
};
let _ = driver.finish(&mut term);   // always restore, even on the error path
result
```

This unifies all three apps on one loop shape and gives the per-turn
full-redraw injection point. `hyprmon` has no worker channels, so its loop is
the minimal one. Added `install_panic_hook` + `idle_interval` helpers
identical to the other apps. New imports: `abstracttui::app::{Driver,
RunConfig}`, `abstracttui::term::UnixTerminal`, `std::time::Instant`.

## Panic / crash terminal restore

The custom `Driver` loops do not get the engine's private
`install_panic_hook`. The added `install_panic_hook` reuses the engine's
public `abstracttui::term::emergency_restore()`, which writes the accumulated
EMERGENCY leave bytes (alt-screen leave, kitty-keyboard pop, cursor/title/
paste/focus resets) to the tty fd and restores termios. Idempotent and safe
under panic-in-panic (a poisoned mutex makes it a quiet no-op). This also
addresses the adjacent "terminal not restored on crash" concern.

## Testing

Integration tests in `rust/*/tests/full_redraw.rs` (repo convention: tests in
`tests/`, no inline tests) using `abstracttui::testing::CaptureTerm` + the
`Driver` headless path (the same harness the existing `tests/view.rs` uses).
Each test mounts a view, drives the engine, and asserts the full-redraw
contract:

1. The initial frame emits a non-empty full screen of bytes.
2. An idle, unchanged turn (no `request_full_redraw`) emits **zero** bytes —
   proving the diff normally suppresses identical cells.
3. The same unchanged state preceded by `request_full_redraw()` emits a
   non-empty full frame again — proving the forced full rewrite.
4. The full rewrite reproduces the same screen content — the desync-healing
   property (re-emitting every cell overwrites whatever the terminal held).

`installer-tui` and `wallpaper-tui` mount their real `ui::root_view`;
`hyprmon` mounts a trivial `dyn_view` (its view is mounted inline in `tui::run`
and not separately exposed, and existing hyprmon tests do not cover the view).
All three tests pass. Existing tests remain green.

## Verification

- `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo
  test` per crate. All clean except one pre-existing, unrelated hyprmon
  `runner.rs` test (`apply_emits_one_eval_per_monitor`) that fails identically
  on the clean tree.
- The full-redraw contract tests pass for all three apps.