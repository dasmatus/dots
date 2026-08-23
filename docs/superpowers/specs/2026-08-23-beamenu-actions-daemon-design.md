# beamenu: plugin actions, utility ports, daemon rewrite

Goal (set via `/goal`, 2026-08-23): add Raycast-style actions for plugins,
port every custom desktop utility into beamenu, and rewrite beamenu as a
systemd user daemon — with the app-runner window remaining exactly as it is.

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

## Part A — actions for plugins

Chosen approach: extend the existing manifest/`alt_actions` machinery.
(Rejected: a C-side overlay panel patch — the frame stack already renders
panels and the patch series should stay minimal.)

1. `Command` gains `#[serde(default)] actions: Vec<CommandAction>` in BOTH
   parsers (`rust/beamenu/src/providers/plugins.rs`,
   `rust/beamenu-canvas/src/manifest.rs`). `CommandAction` is
   `{id, title, mode, ui (default Log), exec}` — a command minus nesting.
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

## Part B — port custom utilities

Everything lands as declarative `programs.beamenu.plugins` manifests (plus
Part A actions) — no new Rust. Inventory from the 2026-08-23 sweep:

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
`nix/home/hyprmon.nix`, `net` in `nix/home/proton.nix` or `waybar.nix`
sibling, `dots` in `nix/home/beamenu.nix` — each module declares its own
plugin next to the tool it ships, the way `settings-menu.nix` already does.
Gate each on the respective module being enabled. Update
`nix/home/keybinds.nix` cheat-sheet text if wording changes.

In scope but already done: `beamenu-record`, screenshots, and system
commands live in the System provider; `settings` and `calc` are plugins.
Out of scope (documented decision): repo-root `scripts/` (dev tooling, not
desktop utilities), `dots-clone` (first-login oneshot), `installer-tui`
(LiveISO only), waybar pills as *renderers* (their functionality gets
launcher commands; the bar keeps polling).

## Part C — systemd user daemon

Chosen approach: one resident daemon that owns the UI thread and shows the
same window on demand. (Rejected: systemd socket activation — cold start
defeats the warm-cache purpose and the daemon needs the Wayland session
anyway. Rejected: daemon that forks a fresh UI process per show — keeps the
scan-per-launch cost and adds a second process model for nothing.)

CLI surface (`rust/beamenu/src/main.rs`):

- `beamenu` (no args, the SUPER+Space bind — unchanged): connect to
  `$XDG_RUNTIME_DIR/beamenu/ipc.sock`, send `show`, exit. If the socket is
  absent/refused, fall back to today's in-process one-shot `run()` so the
  launcher works on a half-configured system. Window UX identical.
- `beamenu daemon`: replaces `--daemon`. Owns: warm state, the socket, the
  clipboard watcher thread (absorbed from `daemon::watch`), the UI loop.
- `beamenu --command <id>`: routed through the daemon when the socket is
  up (single writer for frecency/state), local fallback otherwise.
  `--list-commands` stays local.

Threading: main thread = UI thread; it blocks on an mpsc channel while
hidden, builds `view::Menu` on `show`, runs the existing `run()` loop,
frees the menu on dismiss, returns to the channel. Socket accept loop on a
second thread translates requests into channel messages and replies
`{"ok":true}` / `{"ok":false,"err":...}`; a `show` while visible is a
no-op reply, never a queue. Clipboard watcher is a third thread (same
logic as today's `daemon.rs`, same jsonl file, still the single writer).

Protocol: newline-delimited JSON, `{"cmd":"show"}`, `{"cmd":"command",
"id":"..."}`, `{"cmd":"status"}`, `{"cmd":"reload"}`. Codec is a pure
module with tests; no serde-untyped passthrough.

Warm state and staleness rules (preserving one-shot semantics):

- Apps index + icon-path cache: built at startup, revalidated per `show`
  by mtime-checking the XDG desktop-file dirs (rescan only on change).
  Per-*show* revalidation, not per-keystroke — that alone removes the
  hot-path IO. No inotify dependency in v1.
- `config.json`, plugin manifests, snippets, quicklinks: re-read per
  `show` (small files; keeps HM switches taking effect like today).
- Frecency: in-memory, write-through on activation, as today.

systemd (`nix/home/beamenu.nix`): `beamenu.service` (`ExecStart=beamenu
daemon`, `ConditionEnvironment=WAYLAND_DISPLAY`,
`PartOf/After=graphical-session.target`, `Restart=on-failure`,
`WantedBy=graphical-session.target`) replaces `beamenu-clipboard.service`;
the `clipboardHistory` option now toggles the watcher thread via config
instead of a separate unit.

Known risk, spiked first: repeated `bm_menu_new`/free cycles in one
process (renderer registry + Wayland globals in patched bemenu were only
ever exercised once per process). Verification is an open/close soak under
nested headless Hyprland (per the established headless-testing practice —
never on the live session). If the C side leaks or wedges across cycles,
the fix is patch 07 in `nix/patches/beamenu/`, with a driver test beside
`pills_scroll_test.cpp`.

Tests: `rust/beamenu/tests/` for protocol codec, mtime revalidation
decision logic, and request routing (fake socket via `UnixStream::pair`);
existing suites must stay green.

## Delivery order and gates

A → B → C (B depends only on A's manifest schema; C touches the same
`main.rs`/`lib.rs` seams last so A/B land against the stable one-shot
model). Every phase: `cargo fmt` + clippy (pedantic per CLAUDE.md), crate
tests in `rust/<crate>/tests/`, and at the end `nix run .#nix-lint`
(beamenu step needs `PKG_CONFIG_PATH`/`LD_LIBRARY_PATH` → `beamenu-view`),
`nix flake check --no-build --impure` locally, plus the headless soak.
`nix build` requires new files to be `git add`ed first (flake filesets copy
tracked files only).
