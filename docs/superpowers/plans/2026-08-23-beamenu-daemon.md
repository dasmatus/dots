# beamenu Systemd User Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** beamenu becomes a resident systemd user daemon that keeps its
desktop-entry index warm and shows the same launcher window on request, while
`beamenu` with no arguments stays the keybind's entry point and still works
with no daemon running.

**Architecture:** One process owns the UI thread (bemenu's Wayland connection
is thread-bound), a UNIX-socket listener thread, and the clipboard-watcher
thread absorbed from today's `--daemon`. The socket speaks newline-delimited
JSON. `beamenu` with no arguments is a thin client that falls back to today's
in-process one-shot when the socket is absent. The desktop-entry scan and icon
resolution move behind a cache revalidated once per *show* instead of once per
keystroke.

**Tech Stack:** Rust std (`std::os::unix::net`, `std::sync::mpsc`), serde,
Home Manager systemd user units.

**Spec:** `docs/superpowers/specs/2026-08-23-beamenu-actions-daemon-design.md`
(Part C).

## Global Constraints

- Comments: only `//!` module-level and `///` per-symbol; inline `//` only for
  genuine subtlety (CLAUDE.md).
- Tests: integration tests in `rust/beamenu/tests/*.rs`. No inline
  `#[cfg(test)]`. **Never write-then-exec a script file from a test** — a
  sibling test thread's `fork()` inherits the still-open write fd and `execve`
  returns `ETXTBSY`; exec `/bin/sh -c '<body>'` instead. Sandbox `/bin/sh` is
  busybox ash, so keep test shell snippets POSIX.
- `rust/beamenu` needs the patched C library on every cargo invocation:
  `export BMV=/nix/store/15znvwlsmkiki3ppp05h2hkh214vjnsf-beamenu-view-0.6.23`
  (re-derive with
  `nix build --impure .#beamenu-view --no-link --print-out-paths` if that path
  is gone), then prefix with
  `PKG_CONFIG_PATH="$BMV/lib/pkgconfig" LD_LIBRARY_PATH="$BMV/lib"`.
- Gate per task: `nix shell nixpkgs#rustfmt -c cargo fmt --all` then
  `cargo clippy --all-targets -- -D warnings -W clippy::all -W clippy::perf -W clippy::pedantic`
  then `cargo test`.
- No new crate dependencies. `std::os::unix::net` covers the socket; adding
  tokio/serde-untagged for this would be a dependency for four message types.
- All nix eval/build commands need `--impure`; `git add` new files before any
  `nix build` (flake filesets copy tracked files only).
- **Never test the launcher on the live Hyprland session.** GUI verification
  runs inside a nested headless compositor:
  `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 Hyprland --config <minimal>`,
  driving it through that instance's `WAYLAND_DISPLAY` and `hyprctl`.
- Never touch or commit `rust/wallpaper-tui/tests/tint.rs`.
- Commit messages: plain, no AI-attribution trailers or session links.

---

### Task 1: Spike — do repeated menu cycles survive in one process?

Everything downstream assumes one process can open and close the bemenu panel
many times. bemenu was only ever driven once per process, its renderers are
`dlopen`ed into unsynchronised globals, and `Menu::new`'s `INIT_OK` guard is a
process-lifetime latch (`rust/beamenu/src/view.rs:183-198`). Find out before
building on it.

**Files:**
- Create (throwaway, deleted in Step 5): `rust/beamenu/examples/soak.rs`

- [ ] **Step 1: Write the soak example**

```rust
//! Throwaway soak: open and close the panel N times in one process.
//!
//! Not a test. Needs a live Wayland display, which is why it is an example
//! run by hand inside a nested headless compositor rather than a #[test].

fn main() -> anyhow::Result<()> {
    let rounds: usize = std::env::args()
        .nth(1)
        .and_then(|a| a.parse().ok())
        .unwrap_or(20);
    let config = beamenu::config::Config::default();

    for round in 0..rounds {
        let mut menu = beamenu::view::Menu::new(&config)?;
        menu.set_items(&[beamenu::item::Item::new(
            "soak",
            format!("round {round}"),
            beamenu::item::Action::None,
        )]);
        // One render, then drop. pump() blocks on a key, so this deliberately
        // does not call it: the question is whether create/render/free cycles
        // leak or wedge, not whether input works.
        drop(menu);
        eprintln!("round {round} ok");
    }
    eprintln!("soak survived {rounds} rounds");
    Ok(())
}
```

If `Menu::set_items` alone does not touch the renderer, add one
`menu.render_once()`-equivalent by calling the smallest existing public method
that forces a frame; if none exists, note it and rely on create/free only,
saying so in the report.

- [ ] **Step 2: Start a nested headless compositor**

```bash
cat > /tmp/claude-1000/-home-matus-Dokumente-codeberg-personal-dots/59ef0e92-f17d-45dc-a9bb-ea295026e5cd/scratchpad/hypr-soak.conf <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
animations { enabled = false }
EOF
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  Hyprland --config /tmp/claude-1000/-home-matus-Dokumente-codeberg-personal-dots/59ef0e92-f17d-45dc-a9bb-ea295026e5cd/scratchpad/hypr-soak.conf \
  > /tmp/claude-1000/-home-matus-Dokumente-codeberg-personal-dots/59ef0e92-f17d-45dc-a9bb-ea295026e5cd/scratchpad/hypr-soak.log 2>&1 &
sleep 3
grep -o 'wayland-[0-9]*' /tmp/claude-1000/-home-matus-Dokumente-codeberg-personal-dots/59ef0e92-f17d-45dc-a9bb-ea295026e5cd/scratchpad/hypr-soak.log | head -1
```

The last line is the nested `WAYLAND_DISPLAY`. If Hyprland refuses to nest,
try `sway` with `WLR_BACKENDS=headless` (weston lacks wlr-layer-shell and is
not an option).

- [ ] **Step 3: Run the soak against it**

```bash
WAYLAND_DISPLAY=<nested> BEMENU_RENDERERS="$BMV/lib/bemenu" \
PKG_CONFIG_PATH="$BMV/lib/pkgconfig" LD_LIBRARY_PATH="$BMV/lib" \
  cargo run --example soak -- 50
```

Expected on success: 50 "round N ok" lines then "soak survived 50 rounds",
exit 0, no ASan-style crash, no hang.

- [ ] **Step 4: Record the verdict.** Two outcomes decide Task 5's shape:
  - **PASS** — the daemon hosts the UI in-process. Continue as written.
  - **FAIL** (crash, hang, or steadily growing RSS across rounds; check with
    `/usr/bin/time -v` or by watching `VmRSS` in `/proc/<pid>/status`) — the
    daemon keeps the warm caches but spawns a short-lived UI child per show:
    it re-execs `/proc/self/exe --show-warm`, writes the serialized warm index
    to the child's stdin, and the child runs today's one-shot path against it.
    Take that branch in Task 5, and say so in the report; the socket, cache,
    and nix work in Tasks 2-4 and 6 are unchanged either way.

- [ ] **Step 5: Delete the throwaway and kill the compositor**

```bash
rm rust/beamenu/examples/soak.rs
rmdir rust/beamenu/examples 2>/dev/null
pkill -f 'Hyprland --config .*hypr-soak.conf'
git status --short   # must show no examples/ leftovers
```

- [ ] **Step 6: No commit.** This task produces a finding, not code.

---

### Task 2: warm desktop-entry index

**Files:**
- Create: `rust/beamenu/src/index.rs`
- Modify: `rust/beamenu/src/lib.rs` (add `pub mod index;`)
- Test: `rust/beamenu/tests/index.rs`

**Interfaces:**
- Consumes: `apps::{data_dirs, scan, resolve_icon, DesktopEntry}`
  (`rust/beamenu/src/providers/apps.rs:115,134,175,21`).
- Produces:
  - `pub struct Index` with `Default`.
  - `pub fn Index::revalidate(&mut self) -> bool` — rescans when a watched dir's
    mtime moved or nothing has been scanned yet; returns whether it rescanned.
  - `pub fn Index::entries(&self) -> &BTreeMap<String, DesktopEntry>`
  - `pub fn Index::icon(&mut self, name: &str) -> Option<PathBuf>` — memoized.
  - `pub fn Index::with_dirs(dirs: Vec<PathBuf>) -> Self` — test seam.
  - `pub struct AppCache(RefCell<Index>)` with `Default`, `AppCache::revalidate(&self) -> bool`,
    `AppCache::entries(&self) -> BTreeMap<String, DesktopEntry>` (cloned snapshot — the
    borrow cannot escape the `RefCell`), `AppCache::icon(&self, name: &str) -> Option<PathBuf>`.
  Task 3 puts `AppCache` on `Ctx`; Task 5's daemon calls `revalidate` per show.

- [ ] **Step 1: Write the failing tests** (`rust/beamenu/tests/index.rs`)

```rust
//! The warm desktop-entry index: when it rescans, and when it must not.

use std::path::PathBuf;

use beamenu::index::{AppCache, Index};

fn write_entry(dir: &std::path::Path, file: &str, name: &str) {
    std::fs::write(
        dir.join(file),
        format!("[Desktop Entry]\nType=Application\nName={name}\nExec=/bin/true\n"),
    )
    .unwrap();
}

#[test]
fn first_revalidate_scans_and_reports_that_it_did() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);

    assert!(index.revalidate(), "an unscanned index must scan");
    assert_eq!(index.entries().len(), 1);
}

#[test]
fn an_unchanged_directory_is_not_rescanned() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);
    index.revalidate();

    assert!(!index.revalidate(), "nothing changed, so nothing to rescan");
}

#[test]
fn a_new_entry_makes_the_index_stale() {
    let dir = tempfile::tempdir().unwrap();
    write_entry(dir.path(), "a.desktop", "Alpha");
    let mut index = Index::with_dirs(vec![dir.path().to_path_buf()]);
    index.revalidate();

    // Directory mtime has one-second granularity on some filesystems, so
    // stamp the directory forward explicitly rather than racing it.
    write_entry(dir.path(), "b.desktop", "Beta");
    filetime::set_file_mtime(dir.path(), filetime::FileTime::from_unix_time(
        filetime::FileTime::from_last_modification_time(&std::fs::metadata(dir.path()).unwrap())
            .unix_seconds() + 5,
        0,
    ))
    .unwrap();

    assert!(index.revalidate(), "a changed directory must rescan");
    assert_eq!(index.entries().len(), 2);
}

#[test]
fn a_missing_directory_is_not_an_error() {
    let mut index = Index::with_dirs(vec![PathBuf::from("/nonexistent/beamenu-test")]);
    index.revalidate();
    assert!(index.entries().is_empty());
}

#[test]
fn icon_lookups_are_memoized_per_name() {
    let cache = AppCache::default();
    // Two lookups of a name that resolves to nothing must agree, and the
    // second must not re-probe the icon themes. Behaviour is observable only
    // through equality here; the memo table is an implementation detail.
    assert_eq!(cache.icon("definitely-not-an-icon"), cache.icon("definitely-not-an-icon"));
}
```

If `filetime` is not already a dev-dependency, do not add it: replace that
block with a `std::fs::File::set_modified` call on the directory handle, or
sleep past the granularity with `std::thread::sleep(Duration::from_millis(1100))`
— prefer `set_modified`, and say which you used.

- [ ] **Step 2: Run to verify failure**

`cargo test --test index` (with the `BMV` prefix). Expected: FAIL — unresolved
module `beamenu::index`.

- [ ] **Step 3: Implement `rust/beamenu/src/index.rs`**

```rust
//! The warm desktop-entry index.
//!
//! A one-shot launcher could afford to walk every `applications` directory and
//! probe the icon themes on each keystroke: the process died a moment later
//! and nothing outlived it. A resident daemon cannot, and it should not have
//! to — the answer only changes when a package is installed or removed.
//!
//! So the scan moves behind [`Index`], revalidated once per *show* by
//! comparing each watched directory's mtime against the stamp taken when it
//! was last read. That keeps the observable freshness exactly where it was —
//! a new application appears the next time the launcher opens — while taking
//! the filesystem out of the keystroke path entirely.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::time::SystemTime;

use crate::providers::apps::{data_dirs, resolve_icon, scan, DesktopEntry};

/// Desktop entries and resolved icon paths, with the stamps that say when to
/// look again.
pub struct Index {
    dirs: Vec<PathBuf>,
    /// Last-seen mtime per directory in `dirs`, `None` when it does not exist.
    /// A directory appearing later is a change like any other.
    stamps: Vec<Option<SystemTime>>,
    entries: BTreeMap<String, DesktopEntry>,
    icons: HashMap<String, Option<PathBuf>>,
    scanned: bool,
}

impl Default for Index {
    fn default() -> Self {
        Self::with_dirs(data_dirs())
    }
}

impl Index {
    /// An unscanned index over `dirs`.
    #[must_use]
    pub fn with_dirs(dirs: Vec<PathBuf>) -> Self {
        Self {
            stamps: vec![None; dirs.len()],
            dirs,
            entries: BTreeMap::new(),
            icons: HashMap::new(),
            scanned: false,
        }
    }

    fn stamps_now(&self) -> Vec<Option<SystemTime>> {
        self.dirs
            .iter()
            .map(|dir| std::fs::metadata(dir).and_then(|m| m.modified()).ok())
            .collect()
    }

    /// Rescan if any watched directory changed, or if nothing was ever
    /// scanned. Returns whether a rescan happened.
    ///
    /// The icon memo is cleared alongside the entries: an icon theme usually
    /// lands in the same package as the desktop file that names it, so a
    /// negative lookup cached from before an install would otherwise stick.
    pub fn revalidate(&mut self) -> bool {
        let now = self.stamps_now();
        if self.scanned && now == self.stamps {
            return false;
        }
        self.entries = scan(&self.dirs);
        self.icons.clear();
        self.stamps = now;
        self.scanned = true;
        true
    }

    #[must_use]
    pub fn entries(&self) -> &BTreeMap<String, DesktopEntry> {
        &self.entries
    }

    /// Resolve an icon name, remembering the answer — including a negative
    /// one, which costs the same directory walk to establish as a hit.
    pub fn icon(&mut self, name: &str) -> Option<PathBuf> {
        if let Some(hit) = self.icons.get(name) {
            return hit.clone();
        }
        let resolved = resolve_icon(name, &self.dirs);
        self.icons.insert(name.to_string(), resolved.clone());
        resolved
    }
}

/// Shared handle to an [`Index`] that a `&Ctx` can still write through.
///
/// [`crate::providers::Provider::query`] takes `&Ctx`, because a provider is
/// meant to be a pure function of the query. Memoizing an icon lookup is the
/// one place that has to write, and it is invisible from outside — the same
/// call returns the same answer either way — which is exactly what interior
/// mutability is for. Single-threaded by construction: the UI owns the `Ctx`.
#[derive(Default)]
pub struct AppCache(RefCell<Index>);

impl AppCache {
    /// See [`Index::revalidate`].
    pub fn revalidate(&self) -> bool {
        self.0.borrow_mut().revalidate()
    }

    /// A snapshot of the entries. Cloned rather than borrowed so no `Ref`
    /// escapes into provider code, where holding one across an `icon` call
    /// would panic the `RefCell`.
    #[must_use]
    pub fn entries(&self) -> BTreeMap<String, DesktopEntry> {
        self.0.borrow().entries().clone()
    }

    /// See [`Index::icon`].
    #[must_use]
    pub fn icon(&self, name: &str) -> Option<PathBuf> {
        self.0.borrow_mut().icon(name)
    }
}
```

`DesktopEntry` must be `Clone` for the snapshot; add `#[derive(Clone)]` to it
in `rust/beamenu/src/providers/apps.rs:21` if it is not already. Register the
module in `rust/beamenu/src/lib.rs` beside the others: `pub mod index;`.

- [ ] **Step 4: Run to verify pass:** `cargo test --test index`. Expected: PASS.

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/index.rs rust/beamenu/src/lib.rs rust/beamenu/src/providers/apps.rs rust/beamenu/tests/index.rs
git commit -m "feat(beamenu): warm desktop-entry index with mtime revalidation"
```

---

### Task 3: route the apps provider through the cache

**Files:**
- Modify: `rust/beamenu/src/providers/mod.rs` (`Ctx`, `:35-42`)
- Modify: `rust/beamenu/src/providers/apps.rs:218-249`
- Modify: `rust/beamenu/src/lib.rs` (`App::new`, add `App::refresh`)
- Modify: `rust/beamenu/tests/plugins.rs:84`, `rust/beamenu/tests/providers.rs:16,316`
- Test: `rust/beamenu/tests/providers.rs`

**Interfaces:**
- Consumes: Task 2's `AppCache`.
- Produces: `Ctx { config, config_dir, state_dir, apps: AppCache }`;
  `App::refresh(&mut self)` — re-reads config, plugin manifests, snippets and
  quicklinks, revalidates the app cache, and resets the navigation stack,
  **carrying the warm cache across the rebuild**. Task 5 calls `refresh`
  before every show.

- [ ] **Step 1: Write the failing test** (append to
  `rust/beamenu/tests/providers.rs`; update its `ctx` helper first so the file
  compiles)

```rust
#[test]
fn refresh_keeps_the_app_cache_warm_across_a_rebuild() {
    let dir = tempfile::tempdir().unwrap();
    let ctx = Ctx {
        config: Config::default(),
        config_dir: dir.path().to_path_buf(),
        state_dir: dir.path().to_path_buf(),
        apps: AppCache::default(),
    };

    assert!(ctx.apps.revalidate(), "first call scans");
    assert!(!ctx.apps.revalidate(), "second call finds nothing changed");
}
```

- [ ] **Step 2: Run to verify failure:** `cargo test --test providers`.
Expected: FAIL — `Ctx` has no field `apps`.

- [ ] **Step 3: Implement.**

Add to `Ctx` in `rust/beamenu/src/providers/mod.rs`:

```rust
    /// Desktop entries and icon paths, kept warm across shows. See
    /// [`crate::index::AppCache`].
    pub apps: crate::index::AppCache,
```

Rewrite `Apps::query` in `rust/beamenu/src/providers/apps.rs` to read the
cache instead of the filesystem — note the entry loop no longer calls
`data_dirs()` or `scan()` at all:

```rust
    fn query(&self, ctx: &Ctx, _query: &str) -> Vec<Item> {
        ctx.apps
            .entries()
            .into_iter()
            .map(|(id, entry)| {
                let exec = clean_exec(&entry.exec);
                let icon = entry.icon.as_deref().and_then(|name| ctx.apps.icon(name));
                let mut item = Item::new(
                    format!("apps:{id}"),
                    entry.name,
                    Action::Launch {
                        exec: exec.clone(),
                        terminal: entry.terminal,
                    },
                )
                .icon(icon);
                if let Some(comment) = entry.comment {
                    item = item.subtitle(comment);
                }
                item.alt(
                    "Open in terminal",
                    Action::Shell(format!("{} -e {}", ctx.config.terminal, exec)),
                )
            })
            .collect()
    }
```

In `rust/beamenu/src/lib.rs`, split `App::new` so the cache can survive a
rebuild:

```rust
    /// Assemble from the on-disk configuration, reusing an already-warm app
    /// cache.
    ///
    /// The cache is the one piece of an `App` worth carrying across a rebuild:
    /// everything else is a small file re-read in microseconds, while the
    /// desktop-entry scan is the expensive part the daemon exists to avoid
    /// repeating.
    fn with_cache(apps: index::AppCache) -> Self {
        let config_dir = config::config_dir();
        let state_dir = config::state_dir();
        let config = Config::load(&config_dir.join("config.json"));
        let disabled = config.disabled.clone();

        let providers = providers::all(&config_dir)
            .into_iter()
            .filter(|p| !disabled.iter().any(|d| d == p.id()))
            .collect();

        Self {
            ctx: Ctx {
                config,
                config_dir,
                state_dir,
                apps,
            },
            providers,
            frecency: frecency::Frecency::load(&frecency::default_path()),
            stack: Stack::new(),
        }
    }

    /// Assemble from the on-disk configuration.
    #[must_use]
    pub fn new() -> Self {
        let app = Self::with_cache(index::AppCache::default());
        app.ctx.apps.revalidate();
        app
    }

    /// Re-read everything that lives on disk before showing the launcher again.
    ///
    /// A one-shot process got this for free by dying. A resident one has to
    /// ask: `config.json` and the plugin manifests are rewritten by a Home
    /// Manager switch, the frecency store may have been written by a
    /// `--command` invocation, and the navigation stack must not survive from
    /// whatever the last show was left in.
    pub fn refresh(&mut self) {
        let apps = std::mem::take(&mut self.ctx.apps);
        *self = Self::with_cache(apps);
        self.ctx.apps.revalidate();
    }
```

`std::mem::take` needs `AppCache: Default`, which Task 2 derived. Add
`use crate::index;` to the imports.

- [ ] **Step 4: Run to verify pass:** `cargo test` (whole crate). Expected:
PASS — every pre-existing provider test included.

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/providers/mod.rs rust/beamenu/src/providers/apps.rs rust/beamenu/src/lib.rs rust/beamenu/tests/providers.rs rust/beamenu/tests/plugins.rs
git commit -m "refactor(beamenu): apps provider reads the warm cache, App::refresh rebuilds around it"
```

---

### Task 4: the IPC protocol

**Files:**
- Create: `rust/beamenu/src/ipc.rs`
- Modify: `rust/beamenu/src/lib.rs` (add `pub mod ipc;`)
- Test: `rust/beamenu/tests/ipc.rs`

**Interfaces:**
- Produces:
  - `pub enum Request { Show, Command { id: String }, Status, Reload }`,
    serde-tagged on `"cmd"`, lowercase.
  - `pub enum Response { Ok, Error { message: String }, Status { visible: bool, apps: usize, providers: usize, version: String } }`,
    serde-tagged on `"reply"`, lowercase.
  - `pub fn socket_path() -> PathBuf`
  - `pub fn encode<T: Serialize>(value: &T) -> String` (JSON plus `\n`)
  - `pub fn decode<T: DeserializeOwned>(line: &str) -> anyhow::Result<T>`
  - `pub fn request(path: &Path, req: &Request) -> Option<Response>` — connect,
    send, read one line; `None` on any I/O or parse failure, which is what
    makes the caller's fallback unconditional.
  - `pub fn bind(path: &Path) -> anyhow::Result<UnixListener>` — creates the
    parent directory and clears a stale socket.
  Task 5 consumes all of these.

- [ ] **Step 1: Write the failing tests** (`rust/beamenu/tests/ipc.rs`)

```rust
//! The daemon protocol: wire format, stale-socket recovery, and the
//! client's silent fallback. None of it needs a compositor.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;

use beamenu::ipc::{bind, decode, encode, request, socket_path, Request, Response};

#[test]
fn requests_round_trip_through_the_wire_format() {
    for req in [
        Request::Show,
        Request::Reload,
        Request::Status,
        Request::Command { id: "lock".into() },
    ] {
        let line = encode(&req);
        assert!(line.ends_with('\n'), "framing is newline-delimited");
        assert_eq!(decode::<Request>(line.trim()).unwrap(), req);
    }
}

#[test]
fn show_is_spelled_the_way_the_wire_format_documents() {
    assert_eq!(encode(&Request::Show).trim(), r#"{"cmd":"show"}"#);
    assert_eq!(
        encode(&Request::Command { id: "lock".into() }).trim(),
        r#"{"cmd":"command","id":"lock"}"#
    );
}

#[test]
fn a_malformed_line_is_an_error_not_a_panic() {
    assert!(decode::<Request>("not json").is_err());
    assert!(decode::<Request>(r#"{"cmd":"nope"}"#).is_err());
}

#[test]
fn requesting_an_absent_socket_yields_none_rather_than_failing() {
    let dir = tempfile::tempdir().unwrap();
    assert!(request(&dir.path().join("missing.sock"), &Request::Show).is_none());
}

#[test]
fn a_served_request_comes_back_decoded() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ipc.sock");
    let listener = bind(&path).unwrap();

    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let req: Request = decode(line.trim()).unwrap();
        assert_eq!(req, Request::Show);
        let mut out = stream;
        out.write_all(encode(&Response::Ok).as_bytes()).unwrap();
    });

    assert_eq!(request(&path, &Request::Show), Some(Response::Ok));
    server.join().unwrap();
}

#[test]
fn bind_reclaims_a_socket_left_behind_by_a_dead_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ipc.sock");
    drop(bind(&path).unwrap());
    assert!(path.exists(), "the file outlives the listener");

    bind(&path).expect("a stale socket file must not block a fresh bind");
}

#[test]
fn the_socket_lives_under_the_runtime_directory_when_there_is_one() {
    // socket_path reads the environment, so assert only the shape that holds
    // either way: a beamenu-owned directory and a stable file name.
    let path = socket_path();
    assert_eq!(path.file_name().unwrap(), "ipc.sock");
    assert!(path.to_string_lossy().contains("beamenu"));
}
```

- [ ] **Step 2: Run to verify failure:** `cargo test --test ipc`. Expected:
FAIL — unresolved module `beamenu::ipc`.

- [ ] **Step 3: Implement `rust/beamenu/src/ipc.rs`**

```rust
//! The daemon protocol.
//!
//! One line of JSON in, one line of JSON out, over a UNIX socket in the
//! runtime directory. Newline framing rather than a length prefix because
//! every message is small, and `socat`/`nc` being able to drive the daemon by
//! hand is worth more here than saving a delimiter scan.
//!
//! The client half never reports a failure to connect. A missing socket is
//! the ordinary state of a machine where the user never enabled the service,
//! and the keybind must still open a launcher there — so [`request`] returns
//! `None` and the caller runs the launcher in-process instead.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// What a client asks the daemon to do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "lowercase")]
pub enum Request {
    /// Open the launcher.
    Show,
    /// Run one system command by id, the `--command` path.
    Command { id: String },
    /// Report what the daemon is holding, for debugging a live session.
    Status,
    /// Drop and rebuild the cached configuration on the next show.
    Reload,
}

/// What the daemon answers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "reply", rename_all = "lowercase")]
pub enum Response {
    Ok,
    Error {
        message: String,
    },
    Status {
        visible: bool,
        apps: usize,
        providers: usize,
        version: String,
    },
}

/// `$XDG_RUNTIME_DIR/beamenu/ipc.sock`.
///
/// Falls back to a per-uid directory under `/tmp` when the session has no
/// runtime directory, which is the case in a bare `ssh` login — the daemon is
/// useless there, but the path has to resolve for the client to decide that.
#[must_use]
pub fn socket_path() -> PathBuf {
    let base = std::env::var_os("XDG_RUNTIME_DIR").map_or_else(
        || {
            // SAFETY: getuid is always successful and has no preconditions.
            let uid = unsafe { libc_getuid() };
            PathBuf::from(format!("/tmp/beamenu-{uid}"))
        },
        PathBuf::from,
    );
    base.join("beamenu").join("ipc.sock")
}

/// `getuid(2)`, declared here rather than pulling in the `libc` crate for one
/// call that cannot fail.
extern "C" {
    #[link_name = "getuid"]
    fn libc_getuid() -> u32;
}

/// JSON plus the newline that frames it.
#[must_use]
pub fn encode<T: Serialize>(value: &T) -> String {
    let mut line = serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string());
    line.push('\n');
    line
}

/// Parse one framed line.
///
/// # Errors
/// Fails when the line is not JSON, or not this message type.
pub fn decode<T: DeserializeOwned>(line: &str) -> Result<T> {
    serde_json::from_str(line).context("malformed protocol line")
}

/// Send one request and read one response.
///
/// Returns `None` whenever the daemon cannot be reached or does not answer
/// intelligibly, so callers can treat "no daemon" and "broken daemon"
/// identically: both mean do it yourself.
#[must_use]
pub fn request(path: &Path, req: &Request) -> Option<Response> {
    let mut stream = UnixStream::connect(path).ok()?;
    stream.write_all(encode(req).as_bytes()).ok()?;
    stream.flush().ok()?;

    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).ok()?;
    decode(line.trim()).ok()
}

/// Listen on `path`, creating its directory and clearing a stale socket.
///
/// A socket file outlives the process that bound it, so a daemon killed with
/// SIGKILL leaves one behind that `bind` would refuse. Probing it with a
/// connect distinguishes the two cases: a refused connection means nobody is
/// listening and the file is debris.
///
/// # Errors
/// Fails when the directory cannot be created, when a live daemon already
/// holds the socket, or when `bind` fails for any other reason.
pub fn bind(path: &Path) -> Result<UnixListener> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("cannot create {}", parent.display()))?;
    }

    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            anyhow::bail!("another beamenu daemon is already listening on {}", path.display());
        }
        std::fs::remove_file(path)
            .with_context(|| format!("cannot clear stale socket {}", path.display()))?;
    }

    UnixListener::bind(path).with_context(|| format!("cannot bind {}", path.display()))
}
```

Register `pub mod ipc;` in `rust/beamenu/src/lib.rs`.

- [ ] **Step 4: Run to verify pass:** `cargo test --test ipc`. Expected: PASS.

- [ ] **Step 5: fmt + clippy per Global Constraints.** Clippy pedantic will
want `#[must_use]` and may object to the `extern "C"` block style; match how
`rust/beamenu/src/dispatch.rs:22-40` already declares `setsid` and follow it.

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/ipc.rs rust/beamenu/src/lib.rs rust/beamenu/tests/ipc.rs
git commit -m "feat(beamenu): unix-socket protocol for the daemon"
```

---

### Task 5: the daemon itself

**Files:**
- Modify: `rust/beamenu/src/daemon.rs`
- Test: `rust/beamenu/tests/daemon.rs`

**Interfaces:**
- Consumes: Task 3's `App::refresh`, Task 4's `ipc::*`, existing
  `daemon::watch`/`log_path`, `system::command_for`, `dispatch::dispatch`.
- Produces: `pub fn serve() -> anyhow::Result<()>` — never returns normally;
  `pub fn handle(app: &mut App, req: &Request) -> Response` — the pure-ish
  request handler Task 5's tests drive directly. Task 6's `main.rs` calls
  `serve`.

- [ ] **Step 1: Write the failing tests** (`rust/beamenu/tests/daemon.rs`)

```rust
//! Request handling, without a compositor. `Show` is the one request that
//! needs a display, so it is the one request these tests do not make.

use beamenu::ipc::{Request, Response};

#[test]
fn status_reports_what_the_daemon_is_holding() {
    let mut app = beamenu::App::new();
    let reply = beamenu::daemon::handle(&mut app, &Request::Status);

    match reply {
        Response::Status { providers, version, .. } => {
            assert!(providers >= 10, "the ten built-in providers are always registered");
            assert_eq!(version, env!("CARGO_PKG_VERSION"));
        }
        other => panic!("expected a status reply, got {other:?}"),
    }
}

#[test]
fn an_unknown_command_id_is_an_error_reply_not_a_dispatch() {
    let mut app = beamenu::App::new();
    let reply = beamenu::daemon::handle(&mut app, &Request::Command {
        id: "definitely-not-a-command".into(),
    });

    match reply {
        Response::Error { message } => assert!(
            message.contains("definitely-not-a-command"),
            "the reply must name the id that was not found: {message}"
        ),
        other => panic!("expected an error reply, got {other:?}"),
    }
}

#[test]
fn reload_rebuilds_and_answers_ok() {
    let mut app = beamenu::App::new();
    assert_eq!(beamenu::daemon::handle(&mut app, &Request::Reload), Response::Ok);
}
```

- [ ] **Step 2: Run to verify failure:** `cargo test --test daemon`. Expected:
FAIL — no function `handle`.

- [ ] **Step 3: Implement.** Keep `watch`, `log_path`, `should_store`,
`history_limit` in `rust/beamenu/src/daemon.rs` exactly as they are; extend
the module docs and add below them:

```rust
/// Answer one request against the live `app`.
///
/// [`Request::Show`] is absent here on purpose: it needs the UI thread and a
/// display, so [`serve`] handles it inline and everything that can be decided
/// without a compositor stays in a function tests can call.
#[must_use]
pub fn handle(app: &mut App, req: &Request) -> Response {
    match req {
        Request::Show => Response::Error {
            message: "show is handled by the UI thread".to_string(),
        },
        Request::Reload => {
            app.refresh();
            Response::Ok
        }
        Request::Status => Response::Status {
            visible: false,
            apps: app.ctx.apps.entries().len(),
            providers: app.providers.len(),
            version: env!("CARGO_PKG_VERSION").to_string(),
        },
        Request::Command { id } => match system::command_for(id) {
            Some(command) => match dispatch::dispatch(
                &Action::Shell(command.to_string()),
                &app.ctx.config.terminal,
            ) {
                Ok(()) => Response::Ok,
                Err(err) => Response::Error { message: err.to_string() },
            },
            None => Response::Error {
                message: format!("unknown command '{id}'"),
            },
        },
    }
}

/// Run the resident daemon: socket, clipboard watcher, and the UI.
///
/// Three threads, and which one is which is forced by the C library. The UI
/// must run on the thread that first touched bemenu, because its renderer
/// keeps the Wayland connection in unsynchronised globals
/// (see [`crate::view::Menu`]) — so the UI gets the main thread, and the
/// socket listener and the clipboard watcher, which are both just blocking
/// reads, get spawned ones.
///
/// # Errors
/// Fails when the socket cannot be bound, which usually means another daemon
/// already holds it.
pub fn serve() -> Result<()> {
    let state = crate::config::state_dir();
    std::fs::create_dir_all(&state)?;

    let path = ipc::socket_path();
    let listener = ipc::bind(&path)?;

    // The watcher outlives any single selection, and losing it must not take
    // the launcher down with it: wl-paste dying (a compositor restart, say)
    // costs clipboard history until the next retry, not the daemon.
    let log = log_path(&state);
    std::thread::spawn(move || loop {
        if let Err(err) = watch(&log) {
            eprintln!("beamenu: clipboard watcher stopped: {err}");
        }
        std::thread::sleep(RETRY_DELAY);
    });

    let visible = Arc::new(AtomicBool::new(false));
    let (tx, rx) = std::sync::mpsc::channel::<(Request, SyncSender<Response>)>();

    let accept_visible = Arc::clone(&visible);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = answer(stream, &tx, &accept_visible);
        }
    });

    let mut app = App::new();
    for (req, reply) in rx {
        let response = if matches!(req, Request::Show) {
            visible.store(true, Ordering::SeqCst);
            // Answering before showing rather than after: the client is a
            // keybind that should not sit blocked for as long as the panel is
            // open, and there is nothing it could do with the outcome anyway.
            let _ = reply.send(Response::Ok);
            app.refresh();
            let outcome = crate::run(&mut app);
            visible.store(false, Ordering::SeqCst);
            if let Err(err) = outcome {
                eprintln!("beamenu: show failed: {err}");
            }
            continue;
        } else {
            handle(&mut app, &req)
        };
        let _ = reply.send(response);
    }

    Ok(())
}

/// Read one request off `stream`, get it answered, and write the reply back.
fn answer(
    mut stream: UnixStream,
    tx: &Sender<(Request, SyncSender<Response>)>,
    visible: &AtomicBool,
) -> Result<()> {
    let mut line = String::new();
    BufReader::new(stream.try_clone()?).read_line(&mut line)?;
    let req: Request = ipc::decode(line.trim())?;

    // A second Show while the panel is up is a double keypress, not a queued
    // one: honouring it later would pop the launcher open again at some
    // arbitrary moment after the user had already dismissed it.
    let response = if matches!(req, Request::Show) && visible.load(Ordering::SeqCst) {
        Response::Error { message: "already visible".to_string() }
    } else {
        let (reply_tx, reply_rx) = std::sync::mpsc::sync_channel(1);
        tx.send((req, reply_tx))?;
        reply_rx.recv()?
    };

    stream.write_all(ipc::encode(&response).as_bytes())?;
    stream.flush()?;
    Ok(())
}
```

Add the imports this needs (`std::io::Write`, `std::os::unix::net::UnixStream`,
`std::sync::atomic::{AtomicBool, Ordering}`, `std::sync::mpsc::{Sender, SyncSender}`,
`std::sync::Arc`, `std::time::Duration`, `crate::dispatch`, `crate::ipc`,
`crate::item::Action`, `crate::providers::system`, `crate::App`) and a
`const RETRY_DELAY: Duration = Duration::from_secs(3);` beside
`COMPACT_INTERVAL`.

**If Task 1's spike came back FAIL**, replace the `Request::Show` arm's
`crate::run(&mut app)` with the child-process branch described in Task 1
Step 4, keeping everything else identical, and add a `///` note on `serve`
saying why the UI is out of process.

- [ ] **Step 4: Run to verify pass:** `cargo test --test daemon`. Expected:
PASS. (`App::new()` in these tests reads the real user config dir, which is
fine: it is a read, and `Status`/`Reload`/unknown-`Command` touch nothing.)

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/daemon.rs rust/beamenu/tests/daemon.rs
git commit -m "feat(beamenu): resident daemon hosting the UI, socket and clipboard watcher"
```

---

### Task 6: client-first CLI

**Files:**
- Modify: `rust/beamenu/src/main.rs`

**Interfaces:**
- Consumes: Task 4's `ipc::{request, socket_path, Request, Response}`,
  Task 5's `daemon::serve`.
- Produces: unchanged argv surface — `beamenu`, `beamenu --daemon`,
  `beamenu --command ID`, `beamenu --list-commands` — with `--daemon` now
  running the full daemon and the other two preferring it when it is up.

- [ ] **Step 1: Rewrite the module docs and `run`**

Module docs, replacing `rust/beamenu/src/main.rs:1-9`:

```rust
//! beamenu's entry point.
//!
//! Four modes, and one rule that shapes them: whatever the daemon can do,
//! this binary must still do on its own. A machine where the user never
//! enabled the service, a session where it crashed, a first login before the
//! unit started — the keybind has to open a launcher in all of them. So
//! `--command` and the no-argument launcher try the socket first and fall
//! back to doing the work in-process, and nothing here treats a missing
//! daemon as an error.
//!
//! Exit codes matter because a keybind is the usual caller and has no
//! terminal to read a message from: 0 for done, 1 for a real failure, 2 for a
//! usage error. Diagnostics go to stderr so `--list-commands` stays pipeable.
```

`--daemon`'s help text becomes:

```rust
    /// Run the resident daemon: launcher host, command socket and clipboard
    /// watcher.
    #[arg(long)]
    daemon: bool,
```

`run`'s body, replacing `rust/beamenu/src/main.rs:68-91`:

```rust
    if cli.daemon {
        daemon::serve()?;
        return Ok(ExitCode::SUCCESS);
    }

    let socket = ipc::socket_path();

    if let Some(id) = &cli.command {
        match ipc::request(&socket, &ipc::Request::Command { id: id.clone() }) {
            Some(ipc::Response::Ok) => return Ok(ExitCode::SUCCESS),
            Some(ipc::Response::Error { message }) => {
                eprintln!("beamenu: {message}");
                eprintln!("beamenu: run --list-commands to see the available ids");
                return Ok(ExitCode::from(EXIT_USAGE));
            }
            // No daemon, or one that answered something else: do it here.
            _ => {}
        }

        let Some(command) = system::command_for(id) else {
            eprintln!("beamenu: unknown command '{id}'");
            eprintln!("beamenu: run --list-commands to see the available ids");
            return Ok(ExitCode::from(EXIT_USAGE));
        };
        // The command list is all shell one-liners, none of which run in a
        // terminal. dispatch still takes one for the Launch arm, and reading
        // it here keeps the emulator out of this file.
        let config = config::Config::load(&config::config_dir().join("config.json"));
        dispatch::dispatch(&Action::Shell(command.to_string()), &config.terminal)?;
        return Ok(ExitCode::SUCCESS);
    }

    if ipc::request(&socket, &ipc::Request::Show).is_some() {
        return Ok(ExitCode::SUCCESS);
    }

    let mut app = App::new();
    beamenu::run(&mut app)?;
    Ok(ExitCode::SUCCESS)
```

Update the `use` line to bring in `ipc` and drop nothing that is still used.

- [ ] **Step 2: Verify it builds and the whole suite still passes**

`cargo build && cargo test` (with the `BMV` prefix). Expected: clean.

- [ ] **Step 3: Verify the argv surface by hand** (no display needed for these)

```bash
target/debug/beamenu --list-commands | head -3
target/debug/beamenu --command definitely-not-a-command; echo "exit=$?"
```

Expected: ids printed; then the unknown-command message and `exit=2`.

- [ ] **Step 4: fmt + clippy per Global Constraints**

- [ ] **Step 5: Commit**

```bash
git add rust/beamenu/src/main.rs
git commit -m "feat(beamenu): prefer the daemon, fall back to running in-process"
```

---

### Task 7: the systemd user unit

**Files:**
- Modify: `nix/home/beamenu.nix:457-474`

**Interfaces:**
- Consumes: Task 6's `beamenu --daemon`.
- Produces: `systemd.user.services.beamenu` replacing
  `systemd.user.services.beamenu-clipboard`.

- [ ] **Step 1: Read the existing unit** at `nix/home/beamenu.nix:457-474`,
including the `lib.mkIf cfg.clipboardHistory` gate around it and the
`clipboardHistory` option's description.

- [ ] **Step 2: Replace it**

```nix
    # One resident process now, not one per keypress. It holds the desktop
    # entry index warm, owns the launcher's Wayland connection, answers the
    # command socket, and runs the clipboard watcher that used to be its own
    # unit — all of which need the graphical session, hence the condition and
    # the ordering.
    systemd.user.services.beamenu = {
      Unit = {
        Description = "beamenu launcher daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = "${lib.getExe beamenuPkg} --daemon";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
```

Keep whatever `lib.getExe`-vs-`${beamenuPkg}/bin/beamenu` form the file
already used, and drop the `clipboardHistory` gate from the unit — the daemon
is now wanted whether or not clipboard history is on. If `clipboardHistory`
gated anything else, leave that alone; if the option now only gates the
`clipboard` provider, say so in the report so its description can be
revisited.

- [ ] **Step 3: Eval-check**

```bash
cd /home/matus/Dokumente/codeberg/personal/dots
host=$(nix eval --impure .#nixosConfigurations --apply 'c: builtins.head (builtins.attrNames c)' --raw)
nix eval --impure ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath"
```

Expected: evaluates clean. Also confirm the old unit is gone:

```bash
user=$(nix eval --impure ".#nixosConfigurations.$host.config.home-manager.users" --apply 'u: builtins.head (builtins.attrNames u)' --raw)
nix eval --impure ".#nixosConfigurations.$host.config.home-manager.users.$user.systemd.user.services" --apply 'builtins.attrNames'
```

Expected: `beamenu` present, `beamenu-clipboard` absent.

- [ ] **Step 4: Commit**

```bash
git add nix/home/beamenu.nix
git commit -m "feat(nix/beamenu): one launcher daemon unit replacing the clipboard watcher"
```

---

### Task 8: end-to-end verification under a nested compositor

**Files:** none — this task produces evidence.

- [ ] **Step 1: Build the release binary**

```bash
cd /home/matus/Dokumente/codeberg/personal/dots && git add -A && nix build --impure .#beamenu --no-link --print-out-paths
```

(`git add -A` first: the flake fileset copies tracked files only. Do not
commit — staging is enough, and `rust/wallpaper-tui/tests/tint.rs` must stay
uncommitted.)

- [ ] **Step 2: Start a nested headless compositor** exactly as in Task 1
Step 2, and note its `WAYLAND_DISPLAY`.

- [ ] **Step 3: Run the daemon inside it**

```bash
XDG_RUNTIME_DIR=$(mktemp -d) WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu --daemon &
sleep 2
```

- [ ] **Step 4: Prove the socket answers**

```bash
XDG_RUNTIME_DIR=<same> printf '{"cmd":"status"}\n' | nc -U <runtime>/beamenu/ipc.sock
```

Expected: a `{"reply":"status", ...}` line with a non-zero `apps` count and
`providers` at least 10. (`nc -U` may be absent; `socat - UNIX-CONNECT:<path>`
works too, and `nix shell nixpkgs#socat -c` gets it.)

- [ ] **Step 5: Show the launcher repeatedly**

```bash
for i in 1 2 3 4 5; do
  XDG_RUNTIME_DIR=<same> WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu
  sleep 1
  WAYLAND_DISPLAY=<nested> grim /tmp/.../scratchpad/show-$i.png
  WAYLAND_DISPLAY=<nested> hyprctl dispatch sendshortcut ",Escape,"
  sleep 1
done
```

Expected: five screenshots each showing the panel, the daemon still alive
between them, and RSS not climbing round over round
(`grep VmRSS /proc/<daemon-pid>/status` before and after).

- [ ] **Step 6: Prove the fallback**

```bash
XDG_RUNTIME_DIR=$(mktemp -d) WAYLAND_DISPLAY=<nested> timeout 5 <store-path>/bin/beamenu
```

With no daemon on that runtime dir, this must still open the panel (screenshot
it) rather than exit immediately.

- [ ] **Step 7: Tear down**

```bash
pkill -f 'beamenu --daemon'
pkill -f 'Hyprland --config .*hypr-soak.conf'
```

- [ ] **Step 8: Report** — attach the screenshots' paths, the status reply, and
the RSS readings. No commit.
