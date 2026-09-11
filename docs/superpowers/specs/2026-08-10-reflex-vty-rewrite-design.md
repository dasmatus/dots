# Rust → Haskell rewrite on reflex-vty design

Date: 2026-08-10
Status: approved (user: "lgtm")
Supersedes the from-scratch `haskell/abstracttui/` port (stashed at `stash@{0}`,
recovered to `/tmp/hs-inspect/haskell/abstracttui/`).

## Context

The three Rust TUI apps (`rust/{hyprmon,installer-tui,wallpaper-tui}`) depend on
the external crate `abstracttui = "0.2"`. A prior session hand-rolled a
from-scratch Haskell port of `abstracttui` (`haskell/abstracttui/`). That port
**compiles cleanly on GHC 9.10.3 and passes its 5 smoke tests** (verified:
`nix build` exit 0, `cabal test` `smoke: 5 passed`), and implements the reactive
core, every widget incl. RichTextView + Image half-block mosaic, Anim, and the
CaptureTerm harness.

The user decided to **switch to a maintained Hackage library** rather than
maintain the hand-rolled reactive core + terminal backend. A 25-agent survey
(brick, vty, reflex-vty, notcurses bindings, ncurses, + discovery) with
adversarial verification picked **reflex-vty** as the top candidate: it is the
only surveyed library with native fine-grained FRP (`Event`/`Dynamic`/`Behavior`
≈ abstracttui's `Signal`/`memo`/`dyn_view`), which preserves the apps'
reactive architecture as a near-1:1 port. brick (runner-up) has zero reactivity
(Elm/MVU) and would force re-architecting all three apps. Image-mosaic is
identical custom work on both (neither ships it; both sit on vty char-cell,
which aligns with abstracttui's unicode-mosaic, no-sixel/kitty contract).

Decision: **faithful API-port fork**. Keep an abstracttui-shaped API on top of
reflex-vty, port the apps near-1:1, and salvage the pure-logic modules from the
working from-scratch port.

## Version pin

- **reflex-vty 1.2.0.0** (Obsidian Systems, BSD-3; released 2026-07-13) via a
  `fetchFromGitHub` + `callCabal2nix` override in the dots flake's
  `haskellPackages`. Its bounds (`reflex >= 0.9.2 && < 1`, `vty >= 6.0 && < 6.7`)
  are satisfied by nixpkgs (`reflex 0.9.4.0`, `vty 6.4`) at the dots flake's
  nixpkgs pin `61b7c44c`.
- 1.2.0.0 provides `Reflex.Vty.Canvas` (mosaic target) and
  `Reflex.Vty.Test.Snapshot` (`imageToGrid` test helper), both absent in the
  nixpkgs-shipped 0.6.2.1.
- **Fallback** if the override proves unbuildnable: pin 0.6.2.1 (zero override)
  and degrade `Canvas`→direct vty `Image` mosaic, `Test.Snapshot`→custom
  vty-`Picture`→`SpanOps` reader. The design is otherwise unchanged.

## Module layout

```
haskell/
  abstracttui/        — compat lib: abstracttui-shaped API on reflex-vty + vty
    src/AbstractTUI/{Prelude,Reactive,Driver,Widgets,Anim,...}
    tests/Smoke.hs    — 5 ported smoke tests
  hyprmon/            — app + executable
  installer-tui/      — app + executable
  wallpaper-tui/      — app + executable
```

Apps depend on `abstracttui`. Each app is a cabal `library` + `executable`.

## Salvaged pure modules (DRY)

Copied from the working from-scratch port and lightly adapted (zero terminal /
reactive dependency, pure data + algorithms; already smoke-tested correct):

- `Base.Color` (Rgba), `Base.Geom` (Point/Size)
- `Gfx.Bitmap` (Vector Rgba, `from_pixels`, `resizeNearest`, `pixelAt`)
- `Gfx.Mosaic` (`MosaicMode`/`ImageFit`/`ImageAlign`, `cellPixels`, sampling)
- `Render.Style` (Span/RichLine/RichText, push-coalesce, wrap)
- `Theme` (TokenSet semantic tokens; default abstract-dark)
- `Anim` (Easing, Clock Fixed/Real, Tween, retargetable Transition), the pure
  parts. The `request_frame` tick wiring is added in the compat layer.
- `Layout.Style` (Dimension Auto/Cells/Percent, Edges, Inset, flex spec)

These survive the library switch because they have no backend coupling.

## Replaced layers

### Reactive core → Reflex
The port's hand-rolled `Reactive` (signal/sigGet/sigSet/sigUpdate) is replaced by
Reflex. A `Scope` shim preserves the abstracttui call shape:

- `newtype Scope t m` carrying the Reflex env (`HasInput`, `HasImageWriter`,
  `HasDisplayRegion`, `HasFocusReader`, `HasTheme`).
- `signal = holdDyn`; `sigGet/sigSet/sigUpdate = readDyn/assignDyn/modifyDyn`;
  `memo = nubDyn`/Dynamic chain; `effect = performEvent`; `dyn_view = switchHold`.
- `useTheme`/`useCaps` = `Dynamic` from the env.
- `newTriggerEvent`'s `fire :: a -> IO ()` **is** `wake_handle().post(...)`.
- `request_frame()` = a fireable tick `Event` (see Driver).

### Terminal + driver → vty
The port's `Term`/`Term.Unix`/`cbits/term.c`/`Render.{Emit,Buffer,Paint}` are
replaced by vty (`Input` events + `Picture`/`Image` output + diff). The driver
loop is reflex-vty's `mainWidget`/`runVtyApp`; its per-frame Behavior sampling
**is** `Driver::turn`. `Turn{events,rendered,emitted,quit,idle}` is derived from
the host: `rendered/emitted` from whether the Picture changed, `quit` from the
halt Event, `idle` from no input + no pending tick.

- `requestFullRedraw` = fire the tick `Event` (forces a re-sample/render).
- `quitter` = the `_vtyResult_shutdown` / halt `Event`.
- `waitUntil(ms)` = host idle poll; `DOTS_TUI_IDLE_MS` env gate paces the loop.

## Widgets (rebuilt on reflex-vty primitives; semantics salvaged)

- **Block** → `Reflex.Vty.Widget.Box` + border (vty `BorderStyle` ascii/unicode/
  rounded) + title + fill + child; focus derived from child range.
- **List** → `Reflex.Vty.Widget.Scroll` + `Text` + `Dynamic Int` selection;
  `on_select` = `Event` on filtered Enter; `scroll_to` via `ScrollableConfig`;
  per-region key routing (Tab/Up/Down/Enter for hyprmon's focus ring) via
  `filterKeys`/`localInput`.
- **TextInput** → `Reflex.Vty.Widget.Input.Text` (text-zipper, handleEditorEvent)
  + placeholder DIY in the render.
- **Button** → `Text` + `clickable`/Enter `Event` → `on_click`.
- **Spinner** → frame-sequence `Dynamic Text` on tick `Event` (salvaged
  `spinnerFrames`).
- **Progress** → fill width ∝ 0..1; sub-cell leading edge via half-block `▀`
  (salvaged sub-cell precision).
- **RichTextView** → salvaged `RichText` → vty `Image` via per-span `Attr`.
- **Image** → mosaic: sample salvaged `Bitmap` to per-cell mosaic glyphs
  (▀▄ half-block / ▖▗ quadrant / sextant / braille) + vty `Attr` fg/bg `Rgba`;
  emit via `Reflex.Vty.Canvas` (1.2.0.0) or direct vty `Image` (0.6.2.1).
  Crossfade = two Canvases/images lerped by a `Dynamic Double` driven by the
  tick `Event`, using the salvaged `Transition` opacity blend.

## Anim

Salvaged (`Easing`/`Clock`/`Tween`/`Transition` are pure). The compat layer adds
the tick wiring: `request_frame()` = tick `Event` from a `performEventAsync`
timer thread while an animation is in flight; zero CPU at idle.
`DOTS_NO_ANIM` = CPP gate that skips tick wiring (instant cuts).

## Worker bridge

`newTriggerEvent` gives `(Event t a, a -> IO ())`; the `fire` callback is captured
by worker threads (installer disk install, wallpaper apply/preview/tint) and
posted straight into the FRP network → `Dynamic` update → re-render. The host
buffers events in a bounded queue (`VtyAppConfig._vtyConfig_eventQueueCapacity`,
default 4096) with backpressure (fire blocks until drained). This is the exact
analog of the Rust `wake_handle().post(move || sig.update(|a| a.on_worker_event(ev)))`,
cleaner than brick's BChan (no manual pattern-match dispatch). For side-effecting
bridges use `performEventAsync`/`PerformEvent`.

## Test harness

- **1.2.0.0:** copy BSD-3 `Reflex.Vty.Test.Snapshot.imageToGrid` into the test
  suite; render a widget to an `Image` → grid → assert `cellChar`/`cellAttr`
  (the `CaptureTerm.cell(x,y).display()` analog). Event-driven tests: a mock
  `Vty` recording `Picture`s + injecting `Event`s, read back via `imageToGrid`.
- **0.6.2.1 fallback:** build the grid reader over vty `Graphics.Vty.Picture`→
  `SpanOps` (`PictureToSpans`/`Span`, available in vty 6.4).
- **Port the existing `Smoke.hs` 5 tests** (paint text, capture round-trip,
  full-redraw contract, shortcut-quit, List focus routing) to the new harness.
  Test *intentions* are reused (DRY). Per-widget tests added alongside each
  widget.
- App integration tests live in each app's `tests/` dir (no inline tests, per
  CLAUDE.md), mirroring the Rust `rust/*/tests/` suites.

## Binaries (executable ports)

Each app's `main.rs`/`cli.rs` is ported to a cabal `executable` (main `Main.hs`).

Common: `clap` → **`optparse-applicative`**; `anyhow::Result` → `IO ()` with
`exitWith`/`exitSuccess`/`exitFailure`; `std::env::var` gates →
`System.Environment.lookupEnv`; `mpsc` worker channels → `newTriggerEvent` fire;
`have_tty`/`UnixTerminal` → vty (vty owns the tty; guard with an `isatty`-style
check via `unix` `stdFd`/`queryTerminal`).

- **hyprmon**: 3 subcommands (`apply`/`watch`/`override`). `apply`/`watch` are
  pure-logic dispatch (no TUI): load `Rules`, run `apply`/`watch`, print/render
  `MonitorSpec`. `override` launches the reflex-vty TUI editor. Thin dispatch;
  logic stays in the library (testable).
- **installer-tui**: no clap. `main`: read `/proc/meminfo` → `swap_size_gib`;
  `disks::list_disks` → autodetect (fall back to manual DiskSelect on any
  failure, never crash-loop on a blank tty1); build `App`; `run` = reflex-vty
  `mainWidget` hosting `Signal App` + `Signal ScreenFx`, draining install/net
  worker `Event`s into `on_install_event`/`on_net_event`, dispatching
  `pending_net_op`/`start_install` to worker threads, advancing `ScreenFx` one
  frame per turn. Reboot side effect fires only when `DOTS_INSTALLER_DRY_RUN` is
  unset and the state machine set `reboot`. Loop paced by `DOTS_TUI_IDLE_MS`.
- **wallpaper-tui**: `optparse-applicative` `Args` (cli.rs surface, identical to
  the Python-era CLI so `random_wp.nix` + Hyprland `exec-once` stay unchanged):
  `--restore`, `--output`, `--mode`, `--color`, `--no-tint`, `--tint-backend`,
  `--cache-previews`, `--preview-size`, `path`. Non-interactive paths
  (`--restore`, `--cache-previews`, `--output PATH`) dispatch and exit.
  Interactive path = reflex-vty `mainWidget` hosting `Signal App` + `Signal Fx`,
  draining apply/tint/preview worker `Event`s, dispatching `PendingOp`,
  advancing `Fx` crossfade per turn, paced by `DOTS_TUI_IDLE_MS`.

Env gates preserved verbatim: `DOTS_INSTALLER_DRY_RUN`, `DOTS_TUI_IDLE_MS`,
`DOTS_NO_ANIM`.

## Per-app full ports (logic + UI + binary)

- **hyprmon** (1561 LOC): `tui.rs`(475)→compat layer (List + key shortcuts
  q/ctrl-s/ctrl-r + focus ring); pure logic `matcher/rules/plan/overrides/watch/
  spec/runner` ported directly (Hyprland IPC via process/`hyprctl` shells);
  `main.rs` 3-subcommand binary.
- **installer-tui** (2674 LOC): `ui.rs`(643)+`app.rs`(507)→wizard screens
  (text/network/diskselect/connecting/installing/failed/done); `fx.rs`(209)→
  salvaged Anim (`ScreenFx` shake/crossfade); `install.rs`(488) worker→fire-Event
  bridge; `config/disks/net` ported; `main.rs` binary.
- **wallpaper-tui** (2634 LOC): `ui.rs`(273)+`app.rs`(331)→compat layer;
  `preview.rs`(129)→`Bitmap`+`Image` mosaic (preview decode via `JuicyPixels`);
  `fx.rs`(154) crossfade→salvaged `Transition`; `tint.rs`(502) + `accent.rs`/
  `awww.rs`/`wallpapers.rs`/`config.rs` ported; `cli.rs`+`main.rs` binary.

## Flake / CI

- `haskellPackages` override block: bump `reflex-vty` to 1.2.0.0
  (`fetchFromGitHub` + `callCabal2nix`) and its missing transitive deps; the four
  cabal packages (`abstracttui`, `hyprmon`, `installer-tui`, `wallpaper-tui`)
  via `callCabal2nix`. GHC from nixpkgs (9.10.x/9.12.x).
- `devShell`: `ghc`, `cabal-install`, `haskell-language-server`, `fourmolu`
  (hls + fourmolu just re-enabled in `nix/home/apps/nixvim.nix`).
- `nix run .#<app>` (`flake/apps.nix`) repoints from the Rust crates to the
  Haskell executables.
- GitLab CI: add a Haskell build + `cabal test` lane; extend `nix run .#nix-lint`
  to run `cabal test` across the four packages.
- `nix run .#iso`/`#nix-smoke` unaffected (they build the LiveISO/NixOS test),
  but the installed-system installer binary becomes the Haskell build.

## Phases

1. **Flake + override + devShell.** Wire the `haskellPackages` override +
  four `callCabal2nix` packages + devShell; verify `nix build .#abstracttui`
  (reflex-vty 1.2.0.0) builds. If override fails, fall back to 0.6.2.1.
2. **Salvage + compat layer.** Copy the pure modules; implement `Scope`/`Signal`/
  `Driver`/`Turn`/`CaptureTerm` on reflex-vty + vty; port `Smoke.hs` 5 tests →
  green.
3. **Widgets + Anim.** Block/List/TextInput/Button/Spinner/Progress/RichTextView/
  Image-mosaic + Anim tick wiring; per-widget tests.
4. **hyprmon** e2e (smallest UI): port `tui.rs` + pure logic + 3-subcommand
  binary; integration tests.
5. **installer-tui** e2e: wizard screens + `ScreenFx` + install/net worker
  bridge + binary; integration tests.
6. **wallpaper-tui** e2e: UI + mosaic preview + crossfade + apply/tint/preview
  worker bridge + binary (incl. non-interactive paths); integration tests.
7. **Cutover.** Drop `rust/{hyprmon,installer-tui,wallpaper-tui}` + the
  from-scratch `haskell/abstracttui/` stash; rewire `nix run .#`; CI lane live.

## Out of scope / non-goals

- Native image protocols (sixel/kitty/iTerm2): abstracttui uses unicode mosaic
  only; vty char-cell is aligned, not a gap.
- Keeping the hand-rolled reactive core / terminal backend: replaced by Reflex
  + vty per the user's "switch to a maintained library" decision.
- A brick/MVU variant: rejected fork (would drop reactivity, re-architect apps).

## Risks

- **reflex-vty ecosystem size** (small, 3 reverse deps) vs brick. Mitigation:
  pin a version; vendor/fork if upstream stalls; core `reflex-frp` is large and
  active.
- **Test harness thinner than brick's** (test-suite-only `imageToGrid`). Closed
  by copying the BSD-3 helper + a ~150-300 line mock-Vty shim.
- **Nix override complexity** for 1.2.0.0. Mitigated: deps satisfiable; clean
  0.6.2.1 fallback degrades only `Canvas`/`Test.Snapshot`.