# Task C report — `rust/beamenu-canvas`

Worktree: `/home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/agent-ad77a2f6e40278035`
Commits (current, rebased onto `feat/beamenu` tip `1785604`): `3dd6d60`
(original feat) + `f032e04` (fix round 1) + `2630f02` (fix round 2, live
compositor verification)

(Written inside the worktree — the shared `.superpowers/sdd/...` path
outside the worktree was blocked by worktree-isolation on the Write tool
despite being touch-writable; controller should read this copy.)

## Fix round 2 (live-compositor verification)

Finding: `beamenu-canvas` never mapped its window on Hyprland — process
alive, worker child spawned correctly, but `hyprctl layers` showed no
`beamenu-canvas` namespace surface and nothing appeared on screen.

**Root cause**: `Canvas::build` never called `window.present()`.
Constructing a `gtk4::ApplicationWindow` does not show it — unlike GTK3's
implicit-show patterns, GTK4 requires an explicit `present()` to realize
and map the window. Without it, `gtk4-layer-shell`'s
`init_layer_shell()`/`set_layer()`/etc. configured a surface that was
never actually mapped, so the compositor never saw it. One-line fix.

While live-testing the fix I found two more real bugs:

1. **Load-order race, permanently blank pane.** `Canvas::eval` called
   `evaluate_javascript` immediately. `load_html` is asynchronous, and a
   plugin worker's very first `ui.render` reliably reaches the channel
   before WebKit finishes parsing `PAGE_SHELL` and executing the inline
   `<script>` that defines `window.__beamenu` — confirmed directly via a
   temporary diagnostic: `evaluate_javascript failed:
   TypeError: undefined is not an object (evaluating
   'window.__beamenu.renderForm')`. Since there's no retry, the pane
   would stay blank forever even once mapped. Fixed: `eval()` now queues
   scripts in a `Vec<String>` behind `Rc<RefCell<_>>` until the
   `WebView`'s `load-changed` signal reports `Finished`, then flushes
   them in order.
2. **Unique-application pileup.** `gtk4::Application` defaults to
   unique-per-`application_id` (D-Bus activation). While repeatedly
   testing, I found each new `beamenu-canvas` invocation was silently
   forwarding to the FIRST long-lived instance instead of starting
   independently — `hyprctl layers` accumulated four stacked
   `beamenu-canvas` surfaces, all owned by one ancient pid, and closing
   any one of them would have `app.quit()`-ed the shared process out
   from under all the others. Each invocation of the argv contract is
   meant to be its own sidecar, so `gtk4::Application::builder()` now
   sets `.flags(gio::ApplicationFlags::NON_UNIQUE)`.

**What's confirmed live** (repeated clean single-instance runs, verified
via `hyprctl layers`, `pgrep`, and screenshots): the window maps as a
correctly namespaced (`beamenu-canvas`), positioned and sized
(600,285/720×540 on this 1920×1080 output with a 30px waybar reservation
— exactly matching `panel_size(0.375)`'s math) overlay-layer surface; the
worker child (`global-settings serve --file ...`) spawns correctly under
the manifest's substituted `exec` argv; a single instance stays a single
process/window per invocation after the `NON_UNIQUE` fix.

**What could NOT be confirmed live**: on-screen content painting. Even
after the `present()` and load-gate fixes, `WebView::is_loading()`
correctly reports `true` immediately after `load_html` (the load is
genuinely requested — this isn't a no-op), but the `load-changed` signal
never fires (confirmed via file-based diagnostics bypassing stderr
entirely, since `connect_load_changed`'s closure never ran even once in
an 18-second window) and the load never completes. I spent substantial
effort trying to root-cause this rather than hand-wave past it:
- Bubblewrap sandbox: `WebKitNetworkProcess`/`WebKitWebProcess` DO spawn
  successfully via `bwrap` (confirmed via `ps -ef`); setting
  `WEBKIT_DISABLE_SANDBOX=1` made no observable difference.
- D-Bus session bus: reachable (`DBUS_SESSION_BUS_ADDRESS` set, socket
  exists) — only the separate a11y bus is unavailable, a common and
  usually harmless warning.
- `/dev/shm`: 7.5G, writable.
- DRI/GPU: `/dev/dri/card1` and `renderD128` both accessible (user in
  the `video` group; `renderD128` is world-writable).
- `WEBKIT_DISABLE_COMPOSITING_MODE=1` / `WEBKIT_DISABLE_DMABUF_RENDERER=1`:
  no difference.
- First-run cache/JIT warmup: still stuck after an 18-second wait with
  explicit, writable `XDG_CACHE_HOME`/`XDG_DATA_HOME` (ruling out a slow
  first-run cache-populate as the cause).

This looks like an IPC-level stall between WebKit's UI process and its
Web/Network helper processes specific to this session's nested,
agent-sandboxed execution context, rather than a defect in the Rust code
— but I could not pin down the exact mechanism, and it should be
spot-checked on a real (non-agent-sandboxed) Hyprland session before
being treated as fully resolved. All temporary diagnostic code (a
file-based `diag()` logger bypassing stderr, entry markers in `main()`/
`connect_activate`, `is_loading`/`uri` probes) was removed before the
final commit — none of it shipped.

**Not verified this round**: Esc-closes-window and worker-child-death.
The available GUI-automation tool's window targeting (`list_windows`,
`press_key` with a `pid` target) does not track layer-shell surfaces —
confirmed directly: `list_windows` only enumerated the terminal, and a
synthetic `Escape` keypress targeted at the canvas's pid failed with "No
window matched pid". The underlying close/kill logic itself
(`connect_close_request` → send `shutdown` for `ui: "rpc"` → 500ms grace
→ `Worker::kill()` SIGKILLs by pid unless the reaper already saw it
exit → `app.quit()`) is unchanged from fix round 1, where it was
implemented and reasoned through carefully (see below) — round 2 only
touched window mapping/rendering, not shutdown. Recommend the controller
verify this specific behaviour on a real session where keyboard input
can reach the layer-shell surface.

Full gates after round 2: `nix build --impure .#beamenu-canvas` green
(91/91 tests, checked twice — once mid-round after cleanup, once as the
final post-rebase confirmation), `cargo fmt --check` clean. Rebased onto
the `feat/beamenu` tip (`1785604`, two more merges landed underneath this
branch — a contrast fix and pill auto-highlight, both touching
`nix/patches/beamenu/**`/`rust/beamenu/**`, neither overlapping this
branch's files) with `git diff feat/beamenu --stat` confirming the
rebased commit touches only `rust/beamenu-canvas/src/{main,window}.rs`.

## Fix round 3 (root cause found — page render confirmed live)

Picked up mid-investigation from round 2's blocked state (window mapped,
worker spawned, but `load-changed` never fired and the pane stayed blank).
Round 2 had already ruled out the bwrap sandbox, D-Bus, `/dev/shm`, DRI/GPU,
compositing-mode env vars, and first-run cache warmup, and concluded — but
could not confirm — that it looked like an IPC-level stall specific to the
agent-sandboxed session. That theory turned out to be wrong: this round ran
directly on the real (non-agent-sandboxed) Hyprland session with genuine
compositor access, and the defect reproduced identically there, so it was a
real code bug, not an environment artifact.

**Root cause**: `Canvas::build`'s `connect_decide_policy` handler
unconditionally called `decision.ignore()` on every `NavigationAction`
policy decision, intending to block the page from navigating away (a link,
a redirect). But WebKit's `decide-policy` signal fires for *every*
main-frame navigation, including the canvas's own `load_html` call —
delivered as `NavigationAction` with `WebKitNavigationAction`'s
`navigation_type()` reporting `WEBKIT_NAVIGATION_TYPE_OTHER` (the type
WebKit uses for app-initiated loads, as opposed to `LINK_CLICKED`,
`FORM_SUBMITTED`, etc.). The handler had no way to distinguish "the app's
own load" from "the page tried to navigate away", so it cancelled its own
`load_html` call before the load ever started. Confirmed directly with a
temporary diagnostic printing `decision_type`/`navigation_type` inside the
handler: every run showed exactly one `decide_policy` call per launch,
`type=NavigationAction nav_type=Some(Other)`, immediately followed by
`decision.ignore()` — after which `is_loading` read `false` for the entire
run (not `true`-then-stalled, as round 2's non-diagnostic-instrumented read
had suggested) and `load-changed` never fired again, not even `Started`.

**Fix** (`rust/beamenu-canvas/src/window.rs`): the handler now downcasts the
decision to `NavigationPolicyDecision`, reads its `navigation_action()`'s
`navigation_type()`, and lets the load proceed (`return false`, i.e. "use
policy") when it's `NavigationType::Other`; every other `NavigationAction`
(and all `NewWindowAction`) is still refused exactly as before. Since
workers can never inject real `<a href>` links or trigger real form
GET/POST (the page's own submit button intercepts `submit` and posts a
message instead — see `shell.rs`), `Other` is in practice the *only*
`NavigationAction` this page will ever produce, so this doesn't reopen the
"no network loads" guarantee; it just stops the canvas from blocking
itself.

Two hypotheses from the round-2/round-3 handoff turned out not to be the
cause and needed no code change: the CSP (`default-src 'none'; script-src
'unsafe-inline'; ...`) was never the problem, since the page's only inline
content is the `<script>` it already allowlists; and widget
realize/map ordering (`load_html` before vs. after `window.present()`) made
no observable difference once `decide-policy` was fixed — tested both
orderings live, and the original round-2 ordering (`load_html` then
`present()`) works fine, so no reorder was kept in the final diff.

**Rendering, live-verified**: with the `decide-policy` fix alone, the page
loaded and `evaluate_javascript`'s `renderForm` call succeeded, but the
inputs and Save button rendered with plain native GTK widget chrome (white
background, washed-out text) instead of the injected dark theme — a second,
smaller bug surfaced only once the page was actually rendering. WebKitGTK
paints form controls (`<input>`, `<select>`, `<textarea>`, `<button>`) via
the native GTK theme engine unless `appearance: none` is set on them, which
silently defeats the `background`/`color`/`border` rules the injected
`WebKitUserStyleSheet` already had; Safari/macOS WebKit doesn't have this
quirk, which is presumably why it wasn't caught by inspection. Fixed in
`theme.rs`'s `stylesheet()`: added `appearance: none; -webkit-appearance:
none;` to the `input`/`select`/`textarea` rule and to `button.primary`.
Checkboxes and radios are explicitly excluded from the `appearance: none`
rule (`input:not([type='checkbox']):not([type='radio'])`) — first attempt
included them, which compiled and built fine but live-testing showed it
also strips their native checked-state indicator with nothing to replace
it, a real regression (the "AI: Claude Code" checkbox, checked by the
manifest's test data, rendered as an empty box indistinguishable from
unchecked); native checkbox/radio rendering was left alone since it already
communicates checked state correctly and this crate has no custom
checkbox/radio artwork.

One authoring slip caught by the build, not by review: the CSS attribute
selectors were first written with double quotes (`[type="checkbox"]`)
inside `stylesheet()`'s `r"..."` Rust raw string, which is delimited by
plain `"` (no `#`-hash escaping) — the embedded `"` characters terminated
the raw string early and failed to compile (`expected ',', found
'"]):not([type="radio'`). Fixed by using single-quoted CSS attribute
selectors (`[type='checkbox']`), valid CSS and clear of the Rust
delimiter.

**Live verification** (real Hyprland session, direct compositor access, not
agent-sandboxed): built via `git add` + `nix build --impure
.#beamenu-canvas`, ran against the `settings edit` manifest/worker fixture
under `XDG_CONFIG_HOME`/`PATH` pointed at the scratchpad fixtures.
`hyprctl layers` showed the namespaced, correctly positioned/sized surface;
`grim` + a crop to the layer's geometry shows the Form fully rendered —
three themed, pre-filled text fields (`Git name`, `Git email`, `Hostname`),
three themed checkboxes with correct checked state (`AI: Claude Code`
checked, matching the fixture's `aiClaude = true`, the other two unchecked),
and a teal-accented `Save` button, all on the dark gradient panel
background — confirming the fix, not just "a" render.

Esc-close and worker-cleanup (pending verification since round 1, since
round 2's GUI-automation tooling couldn't target the layer-shell surface's
keyboard input): sent a synthetic `Escape` via `wtype -k Escape` against the
live, focused (keyboard-mode EXCLUSIVE) instance. Confirmed via `pgrep`
immediately after: both the `beamenu-canvas` process and the
`global-settings serve` worker child exited, and `hyprctl layers` no longer
listed the surface — the round-1 `connect_close_request` →
`shutdown_notification` → grace period → `Worker::kill` → `app.quit()` path
works end to end on a real session.

All temporary diagnostics added during this round (stderr prints in
`decide_policy`, `load_changed`, `connect_web_process_terminated`,
`connect_load_failed`, a 500ms polling tick logging `is_loading`, and
markers around `present()`/`load_html`) were removed before the final
commit — none of it shipped; `git diff feat/beamenu --stat` confirms the
committed diff touches only `rust/beamenu-canvas/src/{window,theme}.rs`.

Full gates: `nix build --impure -L .#beamenu-canvas` green — 91/91 tests
across 8 binaries (15+9+6+12+17+15+8+9), `cargo fmt --check` clean (ran
`cargo fmt` once first — the `decide-policy` fix's `is_some_and` closure
needed rustfmt's line-wrap). Rebased onto `feat/beamenu` tip `b496836`.

## Fix round 1 (post-review)

Four findings came back from review. Addressed all:

**F1 (critical, out-of-scope revert).** Root cause, once investigated:
not a `git add -A` staleness bug as suspected — my original commit
(`8498427`), diffed against its *actual parent* `e737ec1`, only ever
touched the 30 in-scope files (verified with `git show --stat`). The
apparent revert was a pure divergence artifact: this branch forked from
`e737ec1` before task A's two follow-up commits (`f04280d`, `9c81c3e`)
landed on `feat/beamenu`, so this branch's tree for `rust/beamenu/**`
and `nix/patches/**` was simply *older*, not edited. Fix: `git rebase
9c81c3e` (the current tip) — applied cleanly, zero conflicts, since my
commit never touched any file task A's two commits touched except one
shared hunk in `nix/home/beamenu.nix` (different lines, merged fine).
Verified: `git diff 9c81c3e --stat` now shows exactly the 30 intended
files, nothing under `rust/beamenu/` or `nix/patches/`. Rebased commit:
`3dd6d60`.

**F2 (critical, dead shutdown + unreachable child).** `Worker::spawn`
moved the whole `Child` into the reaper thread (needed since `wait()`
blocks for the process's lifetime), so nothing could ever call `kill()`
or actually send the built `shutdown_notification()`. Refactored
`Worker` to additionally keep `pid: u32` (from `child.id()`, captured
before the move) and a shared `Arc<AtomicBool>` "exited" flag the reaper
sets right before it reports the exit over the channel. Added
`Worker::kill(&self)`: `SIGKILL`s by pid via a raw `extern "C"` binding
(matching `rust/beamenu/src/dispatch.rs`'s existing `setsid` FFI
pattern, no new crate dependency), skipped if `exited` is already set.
`main.rs` gained `connect_shutdown`, wired to `canvas.window
.connect_close_request` (which the pre-existing Esc handler's
`window.close()` already funnels through): hides the window immediately
(instant-feeling close), sends `shutdown` first for `ui: "rpc"`, then
after a 500ms grace period (`SHUTDOWN_GRACE`) kills the child
unconditionally (both ui modes — the log-mode orphan is the same
defect) and calls `app.quit()`. `app.hold()` returns an
`ApplicationHoldGuard` whose `Drop` is the actual release — the release
build's own `unused_must_use` warning caught that I'd first discarded it
as a bare statement (a no-op hold); fixed by keeping it alive in a
shared `Rc` cloned into the one-shot grace timer.

**F4 (important, ANSI truecolor).** `apply_sgr` iterated every
`;`-separated SGR param independently, so `ESC[38;2;0;255;0m`
(truecolor green) hit the `0 => reset` arm on its own component values
(and `38;5;0`'s palette index would too). Fixed: on seeing `38`/`48`
(extended foreground/background — SGR codes, not related to the ANSI
colour range 30-37 handled elsewhere), the next 2 params (`;5;n`) or 4
params (`;2;r;g;b`) are consumed as a unit via the same param iterator
before the loop continues, matching the existing "16-colour stays as-is"
scope: extended colours are still not rendered, but no longer corrupt
unrelated state. Added 4 tests: truecolor sequence leaves colour/bold
state untouched, `ESC[0m` after a truecolor sequence still resets,
256-colour index ignored without corrupting the *next* code in the same
sequence, and specifically a 256-colour index of `0` not being misread
as reset.

Verification after all four fixes: `git add` targeted (not `-A`) to the
4 changed files (`ansi.rs`, `main.rs`, `worker.rs`, `tests/ansi.rs`);
`nix build --impure -L .#beamenu-canvas` — clean, 91/91 tests passing,
zero compiler warnings (grepped the full build log for "warning" —
only the expected `--impure` "Git tree is dirty" notice); `cargo fmt
--check` clean. Pedantic clippy still not run — see the original
Verification section below; did not re-attempt a third time given two
independent environment-blocker attempts already exhausted (ad-hoc `nix
shell` missing transitive `PKG_CONFIG_PATH`; `nix develop --impure
.#beamenu-canvas` hitting the pre-existing, unrelated `flake/devshell
.nix` `haskellPackages`-arg eval error).

Deferred to ledger by the coordinator, no action taken: CSS token
quote-escaping, explicit WebKitSettings hardening beyond CSP+
decide_policy, the `"id": null` notification edge case.

---

## Original report (commit `8498427`, since rebased to `3dd6d60`)

## Starting state note

The worktree branch was 5 commits behind `feat/beamenu` (it had branched
before the beamenu rename, so `rust/beamenu`, `flake/packages.nix`'s
`beamenu` entry, etc. didn't exist yet). Fast-forwarded the worktree branch
onto `feat/beamenu` (`git merge --ff-only feat/beamenu`) before starting —
a non-destructive fast-forward, no local work existed yet.

## What was implemented

### Crate: `rust/beamenu-canvas`

Binary `beamenu-canvas`, argv `--manifest <path> --command <id> [--query
<string>]` (binding contract, unchanged). Split into a pure-model lib
(`src/lib.rs`) with no `gtk4`/`webkit6`/`gtk4-layer-shell` imports, plus
binary-only GTK/WebKit glue (`main.rs`, `window.rs`, `worker.rs`):

- `manifest.rs` — manifest schema, `find_command`/`command`, `{query}`
  substitution into `exec` argv elements.
- `component.rs` — the closed `Component` enum (`Detail{markdown}`,
  `Log`, `Form{fields,submit_label}`) via a serde internally-tagged enum;
  anything outside the schema (unknown `type`, missing required field,
  unknown form field `type`) fails `Component::validate` with a message
  meant to render straight into the pane. There is structurally no
  variant that carries raw HTML.
- `rpc.rs` — JSON-RPC 2.0 envelope: `parse_incoming` distinguishes
  worker→canvas notifications from responses to canvas-sent requests,
  rejects a "request from worker" (method+id together, never valid in
  this direction), wrong `jsonrpc` version, and malformed responses.
  `form_submit_request`/`shutdown_notification` build the two outgoing
  message shapes.
- `dispatch.rs` — `dispatch_notification` ties `rpc` + `component`
  together into a `CanvasEvent` (`Render`/`LogAppend`/`Error`).
- `ansi.rs` — SGR colour (30-37/90-97) + bold (1/22) parsing, everything
  else (cursor movement, OSC title sequences, arbitrary escapes) stripped
  without being echoed; `to_html` renders spans as canvas-generated,
  escaped `<span class="ansi-...">` markup (classes defined in the one
  stylesheet, not inline colours).
- `markdown.rs` — tiny renderer: headings, bold/italic, inline
  code/fences, lists, links-as-text (renders the label, drops the URL).
  Every literal text run is HTML-escaped before being wrapped in
  canvas-generated tags, including inside fenced code and link labels —
  verified by tests that embed `<script>`/`<img onerror>` in markdown
  input.
- `theme.rs` — `CanvasTheme`, serde-defaulted to the brief's binding
  values (Manrope/JetBrains Mono, `#0d1013` bg, `#171c22→#0d1013` panel
  gradient, `#1e252c`/`#262e36` borders, `#e6ebef` text, `#5b6672` muted,
  `#7fd6c2` accent, `#08110e` fixed primary-button text). `stylesheet()`
  is the only place CSS text is built; focus ring is `hex_to_rgba(accent,
  0.2)`.
- `config.rs` — duplicate tiny loader (width_factor default 0.375,
  `theme.canvas`), does not link `beamenu`, matching the brief.
- `shell.rs` — the static page (`PAGE_SHELL`, CSP `default-src 'none'`)
  loaded once via `load_html`, plus pure `evaluate_javascript` call
  builders (`call_render_detail`/`call_render_log`/`call_append_log`/
  `call_append_stderr`/`call_show_exit`/`call_render_form`) that
  JSON/JS-string-escape every worker-derived string before it lands in a
  script.
- `window.rs` (binary-only) — the one place `gtk4`/`webkit6`/
  `gtk4-layer-shell` are used: layer-shell overlay surface, namespace
  `"beamenu-canvas"`, keyboard mode EXCLUSIVE (toggled to NONE around an
  in-flight `form.submit`, per the pkexec focus-handoff requirement), no
  anchors (centred), sized from `width_factor` against a 1920px
  reference (matching `nix/home/beamenu.nix`'s convention). Injects the
  one stylesheet via `WebKitUserContentManager`/`UserStyleSheet`; blocks
  `NavigationAction`/`NewWindowAction` policy decisions (the concrete
  mechanism behind "disable remote loads — local content only via
  load_html"); wires the page's `formSubmit` script-message handler back
  to a Rust callback. Esc closes the window (`EventControllerKey`).
- `worker.rs` (binary-only, no GTK types) — spawns the command's `exec`,
  pipes stdout/stderr line-by-line and exit status to the main thread
  over `std::sync::mpsc` (the `glib::MainContext::channel` convenience
  API this would otherwise use was removed upstream at the resolved glib
  version — confirmed via docs.rs before writing the workaround), drained
  by a `glib::source::timeout_add_local` 16ms tick in `main.rs`.
- `main.rs` — wires CLI → manifest lookup → `{query}` substitution →
  `Canvas::build` → `ui: "log"` (ANSI-rendered stdout/stderr streaming,
  exit status shown) or `ui: "rpc"` (dispatch notifications into the
  pane; `form.submit` round trip with the keyboard-mode toggle and
  response-id matching).

### Packaging

- `flake/packages.nix` — `beamenu-canvas` via
  `pkgs.rustPlatform.buildRustPackage`, `nativeBuildInputs = [ pkg-config
  wrapGAppsHook4 ]`, `buildInputs = [ gtk4 webkitgtk_6_0 gtk4-layer-shell
  ]` (all three confirmed present in this nixpkgs pin by grepping the
  fetched source, not guessed).
- `flake/nixos.nix` — `beamenuCanvasPkg` specialArg.
- `nix/modules/users.nix` — `beamenuCanvasPkg` in the module's args and
  in `extraSpecialArgs`, following `beamenuPkg`'s existing path exactly.
- `nix/home/beamenu.nix` — `beamenuCanvasPkg` parameter, added to
  `home.packages`.
- `nix/home/hyprland.nix` — a second `layer_rule` entry
  (`beamenu-canvas-blur`, `namespace = "beamenu-canvas"`) alongside the
  existing `beamenu-blur` one (`namespace = "menu"`), same
  `blur`/`ignore_alpha` settings. Kept as two list entries rather than
  one regex, since I could not confirm from the existing code whether
  Hyprland's `match.namespace` does regex or exact matching, and two
  entries is correct either way.
- `.gitignore` — added `rust/beamenu-canvas/target/`, matching the
  per-crate pattern already used for the other Rust crates (the blanket
  `*/target/` only matches one directory level, not
  `rust/beamenu-canvas/target/`).

## Tests: `rust/beamenu-canvas/tests/` — 87 tests, all passing

- `manifest.rs` (12) — full manifest parsing, default/explicit `ui`,
  `find_command`/`command` (including the missing-id error path),
  malformed JSON, missing required field, unknown `mode` value,
  `{query}` substitution (every occurrence, missing query → empty
  string, no-placeholder no-op).
- `component.rs` (9) — accepts all three component shapes incl. every
  form field type; rejects unknown `type`, missing required field,
  unknown form field `type`, non-object; structural check that
  serializing a `Form` never emits an `"html"` key.
- `rpc.rs` (15) — notification/response parsing incl. version rejection,
  request-from-worker rejection, malformed-response cases;
  `form_submit_request` mixed-type value serialization;
  `shutdown_notification` shape.
- `dispatch.rs` (6) — ties `rpc`+`component` together; valid tree →
  Render, invalid tree/missing field/unknown method → Error.
- `ansi.rs` (11) — standard/bright colours, bold, combined SGR, reset,
  stripped cursor-movement and OSC sequences (both BEL- and ST-
  terminated), `to_html` escaping/wrapping.
- `markdown.rs` (17) — headings, paragraphs (join/blank-line-split),
  bold/italic, inline code, fenced code (verbatim, language class, no
  inline parsing inside), lists, links-as-text, and five
  raw-HTML-escaping tests (plain text, inline code, heading, fenced
  code, link label).
- `theme.rs` (9) — binding defaults match the brief's literal values,
  partial-override parsing, `hex_to_rgba` (incl. 8-digit and malformed
  input), generated stylesheet contains every token and the correct
  focus-ring alpha, reacts to a custom accent.
- `shell.rs` (8) — CSP presence, and every `evaluate_javascript` call
  builder correctly JSON-escapes quotes/newlines/apostrophes.

No inline `#[cfg(test)]` blocks anywhere.

## Verification

`git add -A` (required before every `nix build`, sandbox only sees
tracked files) then `nix build --impure -L .#beamenu-canvas` — passed
clean on the final iteration: release build, `cargo test` in checkPhase
(87/87 passing across 8 test binaries + 0 doctests + 0 inline unit
tests), `wrapGAppsHook4` wrapping, fixup, all completed with exit 0.
Re-ran `nix build --impure .#beamenu-canvas` once more after the rustfmt
pass as a final confirmation — exit 0.

`nix shell nixpkgs#rustfmt -c cargo fmt --manifest-path
rust/beamenu-canvas/Cargo.toml` — applied, `-- --check` now clean.

Pedantic clippy: attempted twice (`nix shell` with the GTK/WebKit libs —
hit missing `PKG_CONFIG_PATH` propagation for the many transitive C libs
gtk4/webkitgtk_6_0 pull in; `nix develop --impure .#beamenu-canvas` — hit
a pre-existing, unrelated flake eval error: `flake/devshell.nix` requires
a `haskellPackages` arg that isn't supplied when evaluating `nix develop`
against a package attribute rather than the `default` devShell). Did not
chase further given the authoritative gate (`nix build`) was green and
per the sibling task-A brief's own allowance ("if clippy is unavailable
in the ambient env, note it in the report"). `cargo fmt` ran clean, and
the code was written with pedantic-clippy idioms in mind throughout
(`#[must_use]`, `map_or_else` over manual match-to-bool, `ok_or_else`,
avoided `as` casts where a fallible conversion made sense) but this is
not a substitute for actually running the linter.

## Notable implementation decisions (not fully spelled out in the brief)

1. **JSON-RPC framing**: the brief doesn't state how messages are framed
   on the child's stdin/stdout. Went with newline-delimited JSON (one
   object per line), the simplest convention and consistent with what a
   worker author would expect without a spec. Both parallel tasks (D:
   Claude log-mode, F: settings Form worker) need to agree with this;
   flagging it here since it's an implicit protocol detail the SDD ledger
   marks as "carried verbatim" but doesn't spell out framing explicitly.
2. **Response `id` type**: parsed as `i64` (JSON number). The canvas is
   the only side that originates request ids (auto-incrementing from 0),
   so this is safe as long as F's worker echoes the id back as a JSON
   number, which is the natural thing to do.
3. **JS bridge mechanism**: `evaluate_javascript` calls from Rust to push
   data into the DOM (detail/log/form rendering), and a
   `WebKitUserContentManager` script-message handler (`formSubmit`) for
   the one direction data needs to travel the other way (form submit
   click → Rust). Not specified in the brief; this is the standard,
   minimal WebKitGTK embedding pattern.
4. **Cross-thread → GTK main loop**: `glib::MainContext::channel` (the
   obvious API) was removed upstream at the resolved glib version
   (confirmed via docs.rs, not assumed) — used a plain
   `std::sync::mpsc::channel` drained by a 16ms `timeout_add_local` tick
   instead of pulling in a new dependency (`async-channel`) not listed in
   the brief's stack.
5. **`gtk4` needs the `v4_10` Cargo feature**: `webkit6`'s generated
   bindings reference `gtk4::Accessible` unconditionally, but `gtk4-rs`
   gates that type behind its `v4_10` feature. Without it the build fails
   inside `webkit6`'s own generated code (not something a patch to my
   crate could route around short of this). Documented in Cargo.toml.

## Self-review findings

- Fixed two real bugs surfaced only by actually building: an ambiguous
  `webview.settings()` call (`gtk4::WidgetExt` vs `webkit6::WebViewExt`,
  both in scope) needed disambiguating to `webkit6::prelude::WebViewExt::
  settings(&webview)`; and an `Rc` move-while-borrowed conflict in
  `run_rpc_mode` (the closure passed to `canvas.on_form_submit(...)`
  can't also capture-by-move the same `canvas` binding used as the
  receiver) — fixed with a second, distinct `Rc` clone for the closure.
- Fixed a raw-string-literal bug in my own `tests/theme.rs`: the content
  `{"accent": "#ff00ff"}` inside a single-hash `r#"..."#` raw string
  contains the literal substring `"#`, which prematurely closes that
  delimiter — needed `r##"..."##`. Caught by the checkPhase compile
  error, not by inspection; double-checked no other test/src raw string
  has the same collision.
- Fixed a genuine logic bug in `rpc::parse_incoming`'s version-mismatch
  error path: used `Value::to_string()` (which renders JSON text, so a
  string value comes back double-quoted, e.g. `"\"1.0\""`) instead of
  `as_str()`; caught by `rejects_wrong_jsonrpc_version` actually failing
  in the checkPhase run, not by review.
- Re-read every file after the `cargo fmt` pass; diffs are whitespace/
  line-wrapping only, nothing semantic changed.
- Verified via nixpkgs source (not guessed) that `webkitgtk_6_0` and
  `gtk4-layer-shell` are valid top-level attribute names in the flake's
  pinned nixpkgs before writing `flake/packages.nix`.

## Concerns for the controller

- The JSON-RPC framing choice (newline-delimited JSON) and the response
  `id` being a JSON number are load-bearing for whoever implements task
  F's `global-settings serve` worker — worth confirming F's brief/
  implementation agrees, since the SDD ledger's C↔F ruling states the
  protocol shapes but not the wire framing.
- Did not verify pedantic clippy cleanly passes (see Verification
  section) — the nix build (release profile, which also runs plain
  `rustc` warnings) surfaced no warnings, but that's not equivalent to
  `-W clippy::pedantic`.
- `nix/home/beamenu.nix`'s `configJson` doesn't currently emit a
  `theme.canvas` key at all (out of scope per the brief's Packaging
  section, which only lists `home.packages` wiring) — the canvas's
  serde defaults cover this today, so nothing is broken, but if a later
  task wants to expose canvas theming as Home Manager options, that's a
  clean addition point (`nix/home/beamenu.nix`'s existing `configJson`
  let-binding).
