# beamenu, a Raycast-parity launcher on patched bemenu

Date: 2026-08-21
Status: approved, in implementation
Replaces: HyprTile (`nix/home/hyprtile.nix`, `flake/packages.nix#hyprtile`)

## Why

HyprTile started as a fullscreen tile launcher and grew into the desktop's
command centre. It now owns the launcher, the power menu, screenshots, screen
recording and the wallpaper daemon. Three things pushed it out.

It is a tile grid, so every action costs a page flip and a spatial scan.
Raycast's model is type, rank, act. On a keyboard-driven desktop that is
simply faster.

Its supply chain is a dead end. The derivation fetches an opaque zip from
hyprtile.org, and no binary cache carries it. That is why `flake/lib.nix` has
to embed the closure in both ISOs just to keep installs working offline.

Its resident-scratchpad machinery is all workaround. SDL3 and GL took long
enough to start that the launcher needed a parked instance in
`special:hyprtile`, a window rule, a focus-loss C patch, and a two-attempt
flock retry in `hyprtile-toggle`. Every piece of that exists to hide a cold
start.

## What replaces it

Two artifacts.

`beamenu-view` is nixpkgs `bemenu` 0.6.23 plus a patch series. It ships
`libbemenu.so` and the renderers. Nobody runs it directly.

`rust/beamenu` is the binary. It links `libbemenu` over FFI, owns the event
loop, and implements every feature.

### Why a library and not a protocol

The obvious design is bemenu-as-view talking JSON over pipes to a provider
process. That turns out to be unnecessary. `client/bemenu.c` is 80 lines. It
calls `run_menu()`, which loops on `bm_menu_run_with_events()` and returns to
the caller after every keystroke. The event loop belongs to the client, so a
Rust program can just be the client. It links the library, owns the loop, and
mutates the item list between iterations.

That deletes a whole IPC layer. No serialization format, no protocol version,
no second process, no framing bugs. Dynamic results, the thing that separates
Raycast from dmenu, become a function call.

Asynchronous results are the one case a synchronous loop cannot serve, because
the renderer blocks in `epoll_wait(efd, ..., -1)` inside `render()`. The
Wayland renderer already runs an epoll set at `wayland.c:657-668`, registering
`fds.display` and `fds.repeat`, so this costs one more fd rather than a loop
rewrite.

## C patch series, `nix/patches/beamenu/`

| Patch | Files | Purpose |
|---|---|---|
| `01-item-richtext` | `lib/bemenu.h`, `lib/internal.h`, `lib/item.c` | `subtitle`, `accessory`, `icon`, `section` on `struct bm_item`, with public setters and getters |
| `02-cairo-raycast-rows` | `lib/renderers/cairo_renderer.h` | Replaces the vertical row loop: 24px icon, title, muted subtitle, right-aligned accessory, section headings, rounded selection pill |
| `03-panel-chrome` | `lib/renderers/cairo_renderer.h` | Search row taller than the list rows, with a hairline separator |
| `04-client-ranking` | `lib/bemenu.h`, `lib/filter.c`, `lib/menu.c` | `BM_FILTER_MODE_NONE` so the client can rank, plus a `bm_menu_free_items` lifetime fix |
| `05-rich-panel-body` | `lib/renderers/cairo_renderer.h` | Paint the panel body, report its real height, bound rows to it |

Patch 04 carries a bug fix worth upstreaming. `bm_menu_free_items` freed
`menu->filter_item` with plain `free()` and left the pointer dangling, but
that item belongs to the menu's lifetime rather than the item list's:
`bm_menu_new` allocates it once and the `BM_KEY_CUSTOM` path writes through it
later. Any client that refills its item list, which one doing its own ranking
must do on every keystroke, would double-free it through the following
`bm_menu_free`.

Two further patches were planned and turned out not to be needed.

A wake-fd patch would add an eventfd to the renderer's epoll set so slow
providers could push results into a blocked frame. Every provider answers in
single-digit milliseconds and `fd`-backed file search returns fast enough to
run synchronously, so nothing yet needs it.

A detail-pane patch would add a right-hand preview for clipboard entries and
file metadata. It is chrome, and the clipboard provider reads fine with a
subtitle instead.

The Ctrl+K action panel needs no C patch at all. It is a frame push on the
Rust navigation stack: swap the item list, `Esc` pops. The same mechanism
serves nested commands. That was the single biggest saving against the
original sketch.

Two traps worth recording for anyone touching the renderer.

`bm_menu_set_color` parses `"#RRGGBB"` with
`sscanf("#%2x%2x%2x%2x", &r, &b, &g, &a)`, so `struct bm_hex_color`'s `.g`
field holds the blue byte and `.b` holds the green one. Every
`cairo_set_source_rgba` call then passes `(r, b, g, a)` and the two swaps
cancel. Break that pairing in new code and green and blue transpose.

bemenu compiles with `-DBM_PLUGIN_VERSION` containing a git sha, and
`library.c` refuses to load a renderer whose reported version differs. The
patched library and its renderers are built from one tree so they always
agree, which also means a patched `libbemenu` can never load a stock nixpkgs
renderer. That isolation is wanted.

## Rust crate, `rust/beamenu/`

```
src/
  main.rs          CLI: beamenu, --command <id>, --daemon
  view.rs          FFI bindings and the safe wrapper over libbemenu
  item.rs          Item and Action
  rank.rs          fuzzy match
  frecency.rs      usage weighting, persisted
  frame.rs         navigation stack
  dispatch.rs      action execution
  providers/       apps, system, calc, emoji, clipboard, snippets,
                   quicklinks, window, files, scripts
tests/             integration tests, never inline, per CLAUDE.md
```

A provider is a pure function of the query string plus a read-only context, so
the whole feature set is testable with no compositor running.

### Parity map

| Raycast core feature | beamenu | v1 |
|---|---|---|
| App launcher | `providers/apps.rs`, XDG `.desktop` scan with frecency | yes |
| System | `providers/system.rs`, lock, logout, suspend, hibernate, reboot, shutdown | yes |
| Calculator | `providers/calc.rs`, expressions and unit conversion | yes |
| Emoji picker | `providers/emoji.rs` | yes |
| Clipboard history | `daemon` plus `providers/clipboard.rs` | yes |
| Snippets | `providers/snippets.rs` | yes |
| Quicklinks | `providers/quicklinks.rs` | yes |
| Window management | `providers/window.rs`, hyprctl clients and dispatch | yes |
| File search | `providers/files.rs`, fd or plocate | yes |
| Script commands | `providers/scripts.rs`, metadata headers | yes |
| Extensions | script commands plus `~/.config/beamenu/extensions/` | yes |
| Hotkeys and aliases | Hyprland binds calling `beamenu --command <id>` | yes |
| Raycast AI | `providers/ai.rs` | deferred, needs an API-key story |
| Notes, Focus, Calendar | none | deferred to a follow-up spec |

## What gets deleted rather than ported

The resident-scratchpad complex exists only to mask SDL3 and GL startup.
Layer-shell plus cairo starts in tens of milliseconds, so all of it goes:
`hyprtile-toggle` with its spawn-if-missing and flock retry, the
`hyprtile-overlay` window rule in `nix/home/desktop/hyprland.nix`,
`nix/patches/hyprtile-rofi-like-overlay.patch`, the `hyprtile-sync-apps`
JSON rewrite pass, and the `~/.hyprtile/config.json` seeding activation.

## Sidecar migration

Removing HyprTile removes three tools the desktop depends on.

Wallpaper. `rust/wallpaper-tui/src/wallpaperd.rs` becomes `awww.rs`, driving
`awww-daemon` and `awww img --outputs <name>`. This restores two things the
module's own comments record as regressions: per-output wallpapers, because
`hyprtile-wallpaperd` had no `-o`, and transitions, dropped when the awww
daemon went. The `~/.hyprtile/config.json` sync and the pidfile stop-and-spawn
dance both go, because awww has real IPC. Transition options return to
`programs.wallpaper-tui`.

Screenshots. `Print` calls `hyprshot -m output`, `SUPER+Print` calls
`hyprshot -m region`.

Recording. `wl-screenrec`, behind a start/stop toggle exposed as a beamenu
system command.

## Settings menu

`rust/settings-global` renders through `rofi -dmenu` today and is the last
rofi consumer. It moves onto beamenu's rich rows so the settings list matches
the launcher, which retires rofi and `nix/home/rofi/` with it. The settings
themselves stay where they are, in `/var/lib/dots/settings.nix`.

## Nix churn

- delete `nix/home/hyprtile.nix` and `nix/patches/hyprtile-rofi-like-overlay.patch`
- add `nix/home/beamenu.nix` for the hotkey, provider toggles, snippets,
  quicklinks, the Tokyonight palette and the clipboard user service
- `flake/packages.nix`, drop `hyprtile`, add `beamenu-view` and `beamenu`
- `flake/lib.nix`, swap the `isoImage.storeContents` embed
- `flake/nixos.nix` and `nix/modules/system/users.nix`, `hyprtilePkg` to `beamenuPkg`
- `nix/home/desktop/hyprland.nix`, drop the window rule and the pre-warm exec,
  repoint `SUPER+D`, `SUPER+SHIFT+E` and `Print`, add `awww-daemon`
- `nix/home/desktop/keybinds.nix`, cheatsheet wording
- stale comments in `default.nix`, `eww/default.nix`, `random_wp.nix`,
  `settings-menu.nix` and `wallpaper-tui.nix`

## Verification gates

- `nix build --impure .#beamenu-view`, the patch series applies and compiles
- `nix build --impure .#beamenu`
- `cargo test` in `rust/beamenu` and `rust/wallpaper-tui`
- `nix eval --impure .#nixosConfigurations.tokyonight.config.system.build.toplevel.drvPath`,
  no dangling `hyprtile` references
