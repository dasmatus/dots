# beamenu: plugin actions, utility ports, daemon rewrite

Goal (set via `/goal`, 2026-08-23): add Raycast-style actions for plugins,
port every custom desktop utility into beamenu, and rewrite beamenu as a
systemd user daemon. The app-runner window remains exactly as it is.

## Current state (what this builds on)

- The Ctrl+K action panel already exists: `Item.alt_actions`
  (`rust/beamenu/src/item.rs:76`), `Stack::actions_frame`
  (`rust/beamenu/src/frame.rs:62`), wired through `Outcome::Alternate` in
  `run()` (`rust/beamenu/src/lib.rs:497-504`). Six built-in providers populate
  it (apps, window, files, emoji, clipboard, snippets).
- Plugins are JSON manifests under `~/.config/beamenu/plugins/*.json`
  (`rust/beamenu/src/providers/plugins.rs`), rendered by
  `programs.beamenu.plugins` (`nix/home/beamenu.nix:268-378`). A manifest
  `Command` maps to exactly one `Mode` (`exec|terminal|copy|view`) and its
  items never get `alt_actions`. Two live plugins: `calc`
  (`beamenu-calc --serve`, RPC) and `settings` (`global-settings serve`).
- `beamenu-canvas` keeps a deliberate duplicate manifest parser
  (`rust/beamenu-canvas/src/manifest.rs`); view actions hand it
  `(manifest path, command id, query)` and it re-resolves itself.
- Process model today: one-shot process per SUPER+Space press ("No IPC, no
  second process", `rust/beamenu/src/lib.rs:8-11`). The only daemon is
  `beamenu --daemon`, a clipboard watcher under `beamenu-clipboard.service`
  (`nix/home/beamenu.nix:457-474`). Apps scanning + icon probing is uncached
  blocking IO re-run per dirty keystroke (`rust/beamenu/src/providers/apps.rs`).
- `view::Menu` is `!Send`/`!Sync`; `bm_init()` is once-per-process
  (`rust/beamenu/src/view.rs:146-198`).

## Part A: actions for plugins

Chosen approach: extend the existing manifest/`alt_actions` machinery.
(Rejected: a C-side overlay panel patch. The frame stack already renders
panels and the patch series should stay minimal.)

1. `Command` gains `#[serde(default)] actions: Vec<CommandAction>` in BOTH
   parsers (`rust/beamenu/src/providers/plugins.rs`,
   `rust/beamenu-canvas/src/manifest.rs`). `CommandAction` is
   `{id, title, mode, ui (default Log), exec}`, a command minus nesting.
   Absent field ⇒ empty ⇒ byte-identical behaviour for existing manifests.
2. `PluginProvider::item` maps each action through the same
   `Mode → Action` translation it already applies to the command itself,
   with the same `{query}` expansion, into `item.alt_actions`.
3. View-mode actions: `Action::View{command: <action id>}` requires the
   canvas lookup to fall back from `commands[]` to each command's
   `actions[]`. Action ids share the command id namespace within a plugin;
   first match wins (loading stays tolerant).
4. `programs.beamenu.plugins.<name>.commands[*].actions` submodule added in
   `nix/home/beamenu.nix` mirroring the command fields (no nested actions).
5. Small built-in enrichment while in there: quicklinks gains
   "Copy URL", scripts gains "Run in terminal". Nothing else.

Tests: `rust/beamenu/tests/plugins.rs` (parse default/empty, mode mapping,
`{query}` expansion inside actions, view action indirection);
`rust/beamenu-canvas/tests/manifest.rs` (actions parse + lookup fallback).

## Part B: port custom utilities

Everything lands as declarative `programs.beamenu.plugins` manifests (plus
Part A actions). No new Rust. Inventory from the 2026-08-23 sweep:

| Plugin (keyword) | Command | Mode / exec |
|---|---|---|
| `wallpaper` (`wp `) | Random wallpaper | exec `wallhaven-random-wallpaper` |
| | Pick wallpaper | terminal `wallpaper-tui`; actions: Restore (`--restore`), Rebuild previews (`--cache-previews`) |
| `monitors` (`mon `) | Apply layout | exec `hyprmon apply` |
| | Override editor | terminal `hyprmon override` |
| `dots` (`dots `) | Keybinds cheatsheet | exec `~/.config/eww/scripts/keybinds.sh --force` |
| | Bootstrap vault keys | terminal `dots-keys` |
| `net` (`net `) | Network status | view/log `nmcli device status`; action: Wi-Fi list (view/log `nmcli device wifi list`) |
| | VPN status | view/log `nmcli connection show --active` |
| | Restart Mail bridge | exec `systemctl --user restart protonmail-bridge` |

Placement: `wallpaper` in `nix/home/wallpaper-tui.nix`, `monitors` in
`nix/home/hyprmon.nix`, `net` in `nix/home/proton/proton.nix` or `waybar.nix`
sibling, `dots` in `nix/home/beamenu.nix`. Each module declares its own
plugin next to the tool it ships, the way `settings-menu.nix` already does.
Gate each on the respective module being enabled. Update
`nix/home/desktop/keybinds.nix` cheat-sheet text if wording changes.

In scope but already done: `beamenu-record`, screenshots, and system
commands live in the System provider; `settings` and `calc` are plugins.
Out of scope (documented decision): repo-root `scripts/` (dev tooling, not
desktop utilities), `dots-clone` (first-login oneshot), `installer-tui`
(LiveISO only), waybar pills as *renderers* (their functionality gets
launcher commands; the bar keeps polling).

## Part C: systemd user daemon

Chosen approach: one resident daemon that owns the UI thread and shows the
same window on demand. (Rejected: systemd socket activation. Cold start
defeats the warm-cache purpose, and the daemon needs the Wayland session
anyway. Rejected: daemon that forks a fresh UI process per show. It keeps
the scan-per-launch cost and adds a second process model for nothing.)

Transport: the **session D-Bus**, not a private socket. It is the bus every
other desktop service on this system already sits on, it gives us
introspection and a name-ownership check for free (`busctl --user`,
`gdbus`), systemd can wait on the name with `Type=dbus`, and it removes
the stale-socket-file problem entirely, because name ownership dies with the
process. zbus is pure Rust, so it adds no C dependency and no
`buildInputs`, the same reasoning already recorded for the AT-SPI bridge
at `nix/home/ai/computer-use-linux-pkg.nix:6-7`. beamenu uses
`cargoLock.lockFile`, so the new dependency costs a lock regeneration and
no hash update.

Interface `dev.dots.Beamenu1` at `/dev/dots/Beamenu`, well-known name
`dev.dots.Beamenu`:

- `Show()`: open the launcher. Idempotent: a second call while the panel
  is up returns Ok without queuing, because that is a double keypress, not
  a request to reopen later.
- `RunCommand(s id)`: the `--command` path. Errors with
  `org.freedesktop.DBus.Error.InvalidArgs` naming the id when unknown.
- `Reload()`: discard cached config/manifests before the next show.
- Read-only properties `Visible: b`, `Apps: u`, `Providers: u`,
  `Version: s`. This is a status surface that costs no method and that
  `busctl --user introspect` renders on its own.

CLI surface (`rust/beamenu/src/main.rs`), argv unchanged:

- `beamenu` (no args, the SUPER+Space bind): call `Show()`; on any bus or
  call failure fall back to today's in-process one-shot `run()`, so the
  launcher still works with no daemon, no session bus, or a crashed
  service. Window UX identical.
- `beamenu --daemon`: now the full daemon, with warm state, bus name, the
  clipboard watcher thread (absorbed from `daemon::watch`), and the UI loop.
- `beamenu --command <id>`: call `RunCommand`, same fallback.
  `--list-commands` stays local and never touches the bus.

Threading: main thread = UI thread; it blocks on an `mpsc` receiver while
hidden, builds `view::Menu` on Show, runs the existing `run()` loop, frees
the menu on dismiss, returns to the receiver. zbus's blocking object
server owns its own thread and dispatches method calls there. `Show` and
`Reload` are fire-and-forget sends onto the channel, so a method call
never blocks for as long as the panel is open. `RunCommand` needs no `App`
state. It needs only `system::command_for` and the configured terminal,
published as an `Arc<RwLock<String>>` the UI thread refreshes, so it
dispatches directly on the bus thread with no cross-thread wait at all. `Visible`,
`Apps` and `Providers` are atomics the UI thread stores after each
refresh. Clipboard watcher is a third thread (same logic, same jsonl
file, still the single writer), restarted with a delay if `wl-paste` dies.

Warm state and staleness rules (preserving one-shot semantics):

- Apps index + icon-path cache: built at startup, revalidated per `show`
  by mtime-checking the XDG desktop-file dirs (rescan only on change).
  Per-*show* revalidation, not per-keystroke, removes the hot-path IO on
  its own. No inotify dependency in v1.
- `config.json`, plugin manifests, snippets, quicklinks: re-read per
  `show` (small files; keeps HM switches taking effect like today).
- Frecency: in-memory, write-through on activation, as today.

systemd (`nix/home/beamenu.nix`): `beamenu.service` (`Type=dbus`,
`BusName=dev.dots.Beamenu`, `ExecStart=beamenu --daemon`,
`ConditionEnvironment=WAYLAND_DISPLAY`,
`PartOf/After=graphical-session.target`, `Restart=on-failure`,
`WantedBy=graphical-session.target`) replaces `beamenu-clipboard.service`;
the `clipboardHistory` option now toggles the watcher thread via config
instead of a separate unit. `Type=dbus` means systemd considers the
service started only once the name is actually on the bus, which is the
readiness signal a private socket could not give us.

Known risk, spiked first: repeated `bm_menu_new`/free cycles in one
process (renderer registry + Wayland globals in patched bemenu were only
ever exercised once per process). Verified by soak under nested headless
Hyprland, per the established headless-testing practice. Never on the
live session.

Outcome: the create/free path itself is clean (300 cycles, 1500
`set_items` calls, RSS flat). But the soak could not call
`bm_menu_render`, because `pump` reaches it only on the far side of a
blocking key poll, so it proved lifecycle safety and nothing about
drawing. The end-to-end run found what it had missed: **3444 kB leaked
per rendered show**, dead flat and linear across twelve cycles.

Cause: `create_buffer` mmaps the shm region and hands the pointer to
cairo, but `struct buffer` never recorded it, so `destroy_buffer` could
not `munmap` and did not. Upstream never had to care. Bemenu draws one
window and exits. Fixed by `nix/patches/beamenu/07-unmap-shm-buffers.patch`,
which stores the pointer and length and unmaps after the cairo surface is
gone. Re-measured: 26640 kB after the first show, 26656 kB after twelve.

The lesson generalises past this bug. A soak that cannot exercise the
work the daemon actually does is not evidence about the daemon; when a
spike has to skip the expensive path, its verdict covers only what it
ran, and the real check is the end-to-end one.

Tests: `rust/beamenu/tests/` for mtime revalidation decision logic and for
request handling driven directly against the interface type, no bus
required. The D-Bus methods are thin wrappers over functions that take
plain arguments, which is what keeps them testable. Bus-level behaviour
(name ownership, introspection, a real `Show`) is verified end to end
under the nested headless compositor rather than in `cargo test`, since a
session bus is not a thing a unit test should conjure. Existing suites
must stay green.

## Delivery order and gates

A → B → C (B depends only on A's manifest schema; C touches the same
`main.rs`/`lib.rs` seams last so A/B land against the stable one-shot
model). Every phase: `cargo fmt` + clippy (pedantic per CLAUDE.md), crate
tests in `rust/<crate>/tests/`, and at the end `nix run .#nix-lint`
(beamenu step needs `PKG_CONFIG_PATH`/`LD_LIBRARY_PATH` → `beamenu-view`),
`nix flake check --no-build --impure` locally, plus the headless soak.
`nix build` requires new files to be `git add`ed first (flake filesets copy
tracked files only).
