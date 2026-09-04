# beamenu Systemd User Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** beamenu becomes a resident systemd user daemon that keeps its
desktop-entry index warm and shows the same launcher window on request, while
`beamenu` with no arguments stays the keybind's entry point and still works
with no daemon running.

**Architecture:** One process owns the UI thread (bemenu's Wayland connection
is thread-bound), a zbus blocking object server on its own thread exporting
`dev.dots.Beamenu1` on the session bus, and the clipboard-watcher thread
absorbed from today's `--daemon`. `beamenu` with no arguments is a thin D-Bus
client that falls back to today's in-process one-shot whenever the call does
not go through. The desktop-entry scan and icon resolution move behind a cache
revalidated once per *show* instead of once per keystroke.

**Tech Stack:** Rust, `zbus` (pure Rust D-Bus, blocking API), `std::sync::mpsc`,
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
- Exactly one new crate dependency: `zbus`. It is pure Rust, so it adds no
  `buildInputs` — the same reasoning already recorded at
  `nix/home/ai/computer-use-linux-pkg.nix:6-7`. beamenu is packaged with
  `cargoLock.lockFile` (`flake/packages.nix:118`), so a regenerated
  `rust/beamenu/Cargo.lock` is the whole packaging change; there is no
  `cargoHash` to update. Do not add tokio: use zbus's blocking API.
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
    Take that branch in Task 5, and say so in the report; the bus interface,
    the cache and the nix work in Tasks 2-4 and 6 are unchanged either way.

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
- Modify: `rust/beamenu/src/index.rs` (already declared in `lib.rs` as
  `pub mod index;` with a one-line stub — do not re-add the module line)
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

### Task 4: the D-Bus interface

**Files:**
- Modify: `rust/beamenu/Cargo.toml`, `rust/beamenu/Cargo.lock`
- Modify: `rust/beamenu/src/ipc.rs` (already declared in `lib.rs` as
  `pub mod ipc;` with a one-line stub — do not re-add the module line)
- Test: `rust/beamenu/tests/ipc.rs`

**Interfaces:**
- Consumes: `system::command_for` (`rust/beamenu/src/providers/system.rs`),
  `dispatch::dispatch`, `item::Action`.
- Produces:
  - `pub const BUS_NAME: &str = "dev.dots.Beamenu";`
    `pub const OBJECT_PATH: &str = "/dev/dots/Beamenu";`
  - `pub enum Signal { Show, Reload }` — what the bus thread hands the UI thread.
  - `pub struct Shared { pub visible: AtomicBool, pub apps: AtomicUsize, pub providers: AtomicUsize, pub terminal: RwLock<String> }`
    with `Shared::new()`; the UI thread writes it, the bus thread reads it.
  - `pub struct Beamenu { tx: Sender<Signal>, shared: Arc<Shared> }` with
    `Beamenu::new(tx, shared)`, exporting `dev.dots.Beamenu1`.
  - `pub fn run_command(id: &str, terminal: &str) -> Result<(), String>` — the
    body of the `RunCommand` method, taking plain arguments so tests can call
    it without a bus.
  - `pub fn show(&self) -> bool` / `pub fn reload(&self) -> bool` as the
    inherent (non-D-Bus) halves the tests drive.
  Task 5 builds the connection; Task 6 calls the interface as a client.

- [ ] **Step 1: Add the dependency**

```bash
cd rust/beamenu
cargo add zbus --no-default-features --features blocking-api
```

zbus's feature names move between majors. If that invocation fails or
`zbus::blocking` is still missing, run `cargo add zbus` plainly and then trim
features until `cargo build` compiles with `zbus::blocking` available and no
tokio in the tree (`cargo tree -i tokio` must find nothing). Record the exact
version and feature list that worked in your report. Do not add `serde` or
`futures` explicitly — zbus re-exports what it needs.

- [ ] **Step 2: Write the failing tests** (`rust/beamenu/tests/ipc.rs`)

```rust
//! The daemon's D-Bus surface, exercised without a bus.
//!
//! Every method body is a plain function over plain arguments, which is what
//! makes this testable: the D-Bus layer contributes the name, the signature
//! and the error mapping, and none of those need a session bus to be right.

use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::Arc;

use beamenu::ipc::{run_command, Beamenu, Shared, Signal, BUS_NAME, OBJECT_PATH};

fn iface() -> (Beamenu, Arc<Shared>, mpsc::Receiver<Signal>) {
    let (tx, rx) = mpsc::channel();
    let shared = Arc::new(Shared::new());
    (Beamenu::new(tx, Arc::clone(&shared)), shared, rx)
}

#[test]
fn the_bus_name_and_path_agree_with_each_other() {
    assert_eq!(BUS_NAME, "dev.dots.Beamenu");
    assert_eq!(OBJECT_PATH, "/dev/dots/Beamenu");
    assert_eq!(
        OBJECT_PATH.trim_start_matches('/').replace('/', "."),
        BUS_NAME,
        "the object path is the bus name's path form, so one cannot drift"
    );
}

#[test]
fn show_signals_the_ui_thread() {
    let (iface, _shared, rx) = iface();
    assert!(iface.show(), "a hidden launcher accepts a show");
    assert_eq!(rx.try_recv().unwrap(), Signal::Show);
}

#[test]
fn show_while_visible_is_a_no_op_rather_than_a_queued_second_panel() {
    let (iface, shared, rx) = iface();
    shared.visible.store(true, Ordering::SeqCst);

    assert!(iface.show(), "a double keypress is not an error");
    assert!(
        rx.try_recv().is_err(),
        "nothing may be queued, or the panel reopens after the user dismissed it"
    );
}

#[test]
fn reload_signals_the_ui_thread() {
    let (iface, _shared, rx) = iface();
    assert!(iface.reload());
    assert_eq!(rx.try_recv().unwrap(), Signal::Reload);
}

#[test]
fn signalling_a_dead_ui_thread_reports_failure_rather_than_panicking() {
    let (iface, _shared, rx) = iface();
    drop(rx);
    assert!(!iface.show(), "a closed channel is a failed send, not an unwrap");
}

#[test]
fn an_unknown_command_id_is_an_error_naming_it() {
    let err = run_command("definitely-not-a-command", "kitty")
        .expect_err("an unknown id cannot dispatch");
    assert!(
        err.contains("definitely-not-a-command"),
        "the message must name the id that was not found: {err}"
    );
}

#[test]
fn properties_read_through_to_what_the_ui_thread_published() {
    let (iface, shared, _rx) = iface();
    shared.apps.store(42, Ordering::SeqCst);
    shared.providers.store(11, Ordering::SeqCst);
    shared.visible.store(true, Ordering::SeqCst);

    assert_eq!(iface.apps(), 42);
    assert_eq!(iface.providers(), 11);
    assert!(iface.visible());
    assert_eq!(iface.version(), env!("CARGO_PKG_VERSION"));
}
```

- [ ] **Step 3: Run to verify failure**

`cargo test --test ipc` (with the `BMV` prefix). Expected: FAIL — nothing in
`beamenu::ipc` yet.

- [ ] **Step 4: Implement `rust/beamenu/src/ipc.rs`**

```rust
//! The daemon's D-Bus interface.
//!
//! The session bus rather than a private socket, because everything the
//! daemon needs from a transport it already has there: `busctl --user` can
//! introspect and drive it by hand, name ownership tells systemd when the
//! service is genuinely up (`Type=dbus`), and a name dies with the process
//! that held it — so there is no stale socket file to reclaim on a crash.
//!
//! Every method body below is an inherent method taking plain arguments, with
//! the `#[zbus::interface]` block a thin wrapper over it. That split is what
//! lets the whole surface be tested without conjuring a session bus.
//!
//! Threading: the object server runs on zbus's own thread, so nothing here
//! may block for as long as the panel is open. [`Beamenu::show`] and
//! [`Beamenu::reload`] hand a [`Signal`] to the UI thread and return
//! immediately; `RunCommand` needs no launcher state at all and so runs
//! inline; the properties read atomics the UI thread publishes.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, RwLock};

use crate::dispatch;
use crate::item::Action;
use crate::providers::system;

/// The well-known name the daemon owns on the session bus.
pub const BUS_NAME: &str = "dev.dots.Beamenu";

/// The object the interface is exported at.
pub const OBJECT_PATH: &str = "/dev/dots/Beamenu";

/// What the bus thread asks the UI thread to do.
///
/// Deliberately only the two things that need the UI thread. Anything that
/// can be answered without it is answered on the bus thread instead, so a
/// method call never waits on a panel the user has not dismissed yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Show,
    Reload,
}

/// State the UI thread publishes and the bus thread reads.
#[derive(Debug)]
pub struct Shared {
    /// True while the panel is up. Read by `Show` to stay idempotent.
    pub visible: AtomicBool,
    pub apps: AtomicUsize,
    pub providers: AtomicUsize,
    /// The configured terminal emulator, republished on every refresh so a
    /// `RunCommand` arriving after a Home Manager switch uses the new one.
    pub terminal: RwLock<String>,
}

impl Shared {
    #[must_use]
    pub fn new() -> Self {
        Self {
            visible: AtomicBool::new(false),
            apps: AtomicUsize::new(0),
            providers: AtomicUsize::new(0),
            terminal: RwLock::new(String::new()),
        }
    }
}

impl Default for Shared {
    fn default() -> Self {
        Self::new()
    }
}

/// Run one system command by id.
///
/// Split out of the D-Bus method so it can be called with two strings.
///
/// # Errors
/// Returns a message naming the id when no such command exists, or the
/// dispatch failure otherwise.
pub fn run_command(id: &str, terminal: &str) -> Result<(), String> {
    let Some(command) = system::command_for(id) else {
        return Err(format!("unknown command '{id}'"));
    };
    // The command list is all shell one-liners; dispatch still wants a
    // terminal for its Launch arm, which is why one is threaded through.
    dispatch::dispatch(&Action::Shell(command.to_string()), terminal)
        .map_err(|err| err.to_string())
}

/// The exported object.
pub struct Beamenu {
    tx: Sender<Signal>,
    shared: Arc<Shared>,
}

impl Beamenu {
    #[must_use]
    pub fn new(tx: Sender<Signal>, shared: Arc<Shared>) -> Self {
        Self { tx, shared }
    }

    /// Ask the UI thread to open the launcher. Returns whether the signal
    /// was delivered — or was deliberately not needed.
    ///
    /// A show while the panel is already up sends nothing and still reports
    /// success: that is a second keypress, and queueing it would reopen the
    /// launcher at some arbitrary moment after the user dismissed it.
    pub fn show(&self) -> bool {
        if self.shared.visible.load(Ordering::SeqCst) {
            return true;
        }
        self.tx.send(Signal::Show).is_ok()
    }

    /// Ask the UI thread to rebuild its cached configuration.
    pub fn reload(&self) -> bool {
        self.tx.send(Signal::Reload).is_ok()
    }

    #[must_use]
    pub fn visible(&self) -> bool {
        self.shared.visible.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn apps(&self) -> usize {
        self.shared.apps.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn providers(&self) -> usize {
        self.shared.providers.load(Ordering::SeqCst)
    }

    #[must_use]
    pub fn version(&self) -> &'static str {
        env!("CARGO_PKG_VERSION")
    }

    fn terminal(&self) -> String {
        self.shared
            .terminal
            .read()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }
}

/// `dev.dots.Beamenu1`.
#[zbus::interface(name = "dev.dots.Beamenu1")]
impl Beamenu {
    /// Open the launcher.
    #[zbus(name = "Show")]
    fn dbus_show(&self) -> zbus::fdo::Result<()> {
        if self.show() {
            Ok(())
        } else {
            Err(zbus::fdo::Error::Failed(
                "the launcher thread is gone".to_string(),
            ))
        }
    }

    /// Run one system command by id.
    #[zbus(name = "RunCommand")]
    fn dbus_run_command(&self, id: &str) -> zbus::fdo::Result<()> {
        run_command(id, &self.terminal()).map_err(zbus::fdo::Error::InvalidArgs)
    }

    /// Rebuild cached configuration before the next show.
    #[zbus(name = "Reload")]
    fn dbus_reload(&self) -> zbus::fdo::Result<()> {
        if self.reload() {
            Ok(())
        } else {
            Err(zbus::fdo::Error::Failed(
                "the launcher thread is gone".to_string(),
            ))
        }
    }

    #[zbus(property, name = "Visible")]
    fn dbus_visible(&self) -> bool {
        self.visible()
    }

    #[zbus(property, name = "Apps")]
    fn dbus_apps(&self) -> u32 {
        u32::try_from(self.apps()).unwrap_or(u32::MAX)
    }

    #[zbus(property, name = "Providers")]
    fn dbus_providers(&self) -> u32 {
        u32::try_from(self.providers()).unwrap_or(u32::MAX)
    }

    #[zbus(property, name = "Version")]
    fn dbus_version(&self) -> String {
        self.version().to_string()
    }
}
```

The `#[zbus::interface]` attribute's exact spelling (`#[zbus::interface]` vs
the older `#[dbus_interface]`), the `#[zbus(name = ...)]` renames and whether
an inherent `impl` may coexist with the interface `impl` all depend on the
zbus major you landed in Step 1. Adapt to what compiles — keeping the split
between plain-argument inherent methods and the D-Bus wrappers, since that is
what the tests bind to — and describe any deviation in your report.

- [ ] **Step 5: Run to verify pass:** `cargo test --test ipc`. Expected: PASS.

- [ ] **Step 6: Confirm the lock file moved and nothing pulled in tokio**

```bash
git diff --stat rust/beamenu/Cargo.lock   # must show additions
cargo tree -i tokio                        # must report nothing
```

- [ ] **Step 7: fmt + clippy per Global Constraints**

- [ ] **Step 8: Commit**

```bash
git add rust/beamenu/Cargo.toml rust/beamenu/Cargo.lock rust/beamenu/src/ipc.rs rust/beamenu/src/lib.rs rust/beamenu/tests/ipc.rs
git commit -m "feat(beamenu): dev.dots.Beamenu1 session-bus interface"
```

---

### Task 5: the daemon itself

**Files:**
- Modify: `rust/beamenu/src/daemon.rs`
- Test: `rust/beamenu/tests/daemon.rs`

**Interfaces:**
- Consumes: Task 3's `App::refresh`, Task 4's `ipc::{Beamenu, Shared, Signal,
  BUS_NAME, OBJECT_PATH}`, existing `daemon::watch`/`log_path`.
- Produces: `pub fn serve() -> anyhow::Result<()>` — never returns normally;
  `pub fn publish(app: &App, shared: &ipc::Shared)` — copies the launcher's
  current counts and terminal into the shared cell, which is the one piece of
  `serve` worth testing without a bus. Task 6's `main.rs` calls `serve`.

- [ ] **Step 1: Write the failing tests** (`rust/beamenu/tests/daemon.rs`)

```rust
//! What the daemon publishes about itself. The bus and the panel both need a
//! live session, so neither appears here; the state they read does.

use std::sync::atomic::Ordering;

use beamenu::daemon::publish;
use beamenu::ipc::Shared;

#[test]
fn publish_copies_the_launchers_counts_into_the_shared_cell() {
    let app = beamenu::App::new();
    let shared = Shared::new();
    publish(&app, &shared);

    assert_eq!(shared.providers.load(Ordering::SeqCst), app.providers.len());
    assert!(
        shared.providers.load(Ordering::SeqCst) >= 10,
        "the ten built-in providers are always registered"
    );
}

#[test]
fn publish_republishes_the_terminal_so_a_reconfigured_one_takes_effect() {
    let mut app = beamenu::App::new();
    let shared = Shared::new();
    app.ctx.config.terminal = "some-other-terminal".to_string();
    publish(&app, &shared);

    assert_eq!(
        shared.terminal.read().unwrap().as_str(),
        "some-other-terminal"
    );
}

#[test]
fn publish_is_idempotent() {
    let app = beamenu::App::new();
    let shared = Shared::new();
    publish(&app, &shared);
    let first = shared.apps.load(Ordering::SeqCst);
    publish(&app, &shared);

    assert_eq!(shared.apps.load(Ordering::SeqCst), first);
}
```

- [ ] **Step 2: Run to verify failure:** `cargo test --test daemon`. Expected:
FAIL — no function `publish`.

- [ ] **Step 3: Implement.** Keep `watch`, `log_path`, `should_store` and
`history_limit` in `rust/beamenu/src/daemon.rs` exactly as they are; extend the
module docs to describe the daemon rather than only the watcher, and add:

```rust
/// Copy what the bus thread reports about the launcher out of `app`.
///
/// Called after every refresh rather than read on demand, because the `App`
/// belongs to the UI thread and a property read arrives on zbus's.
pub fn publish(app: &App, shared: &ipc::Shared) {
    shared
        .apps
        .store(app.ctx.apps.entries().len(), Ordering::SeqCst);
    shared.providers.store(app.providers.len(), Ordering::SeqCst);
    if let Ok(mut terminal) = shared.terminal.write() {
        terminal.clone_from(&app.ctx.config.terminal);
    }
}

/// Run the resident daemon: bus name, clipboard watcher, and the UI.
///
/// Three threads, and which one is which is forced by the C library. The UI
/// must run on the thread that first touched bemenu, because its renderer
/// keeps the Wayland connection in unsynchronised globals (see
/// [`crate::view::Menu`]) — so the UI keeps the main thread, and zbus's object
/// server and the clipboard watcher, which both only block on reads, get
/// threads of their own.
///
/// # Errors
/// Fails when the session bus is unreachable or when the well-known name is
/// already owned, which means another daemon is running.
pub fn serve() -> Result<()> {
    let state = crate::config::state_dir();
    std::fs::create_dir_all(&state)?;

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

    let shared = Arc::new(ipc::Shared::new());
    let (tx, rx) = std::sync::mpsc::channel::<ipc::Signal>();

    // Held for the process's lifetime: dropping the connection releases the
    // well-known name, and systemd's Type=dbus readiness is that name.
    let _connection = zbus::blocking::connection::Builder::session()
        .context("no session bus")?
        .name(ipc::BUS_NAME)
        .context("another beamenu daemon already owns the name")?
        .serve_at(ipc::OBJECT_PATH, ipc::Beamenu::new(tx, Arc::clone(&shared)))?
        .build()?;

    let mut app = App::new();
    publish(&app, &shared);

    for signal in rx {
        match signal {
            ipc::Signal::Show => {
                shared.visible.store(true, Ordering::SeqCst);
                app.refresh();
                publish(&app, &shared);
                let outcome = crate::run(&mut app);
                shared.visible.store(false, Ordering::SeqCst);
                if let Err(err) = outcome {
                    eprintln!("beamenu: show failed: {err}");
                }
            }
            ipc::Signal::Reload => {
                app.refresh();
                publish(&app, &shared);
            }
        }
    }

    Ok(())
}
```

Add the imports this needs (`std::sync::atomic::Ordering`, `std::sync::Arc`,
`std::time::Duration`, `anyhow::Context`, `crate::ipc`, `crate::App`) and
`const RETRY_DELAY: Duration = Duration::from_secs(3);` beside
`COMPACT_INTERVAL`. The zbus builder's exact path
(`zbus::blocking::connection::Builder` vs `zbus::blocking::ConnectionBuilder`)
depends on the major you landed in Task 4 — adapt and report.

**If Task 1's spike came back FAIL**, replace the `crate::run(&mut app)` call
with the child-process branch described in Task 1 Step 4, keeping everything
else identical, and add a `///` note on `serve` saying why the UI is out of
process.

- [ ] **Step 4: Run to verify pass:** `cargo test --test daemon`. Expected:
PASS. (`App::new()` here reads the real user config dir, which is fine: it is
a read, and nothing in these tests dispatches or draws.)

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/daemon.rs rust/beamenu/tests/daemon.rs
git commit -m "feat(beamenu): resident daemon owning the bus name, UI and clipboard watcher"
```

---

### Task 6: client-first CLI

**Files:**
- Modify: `rust/beamenu/src/main.rs`

**Interfaces:**
- Consumes: Task 4's `ipc::{BUS_NAME, OBJECT_PATH}`, Task 5's `daemon::serve`.
- Produces: unchanged argv surface — `beamenu`, `beamenu --daemon`,
  `beamenu --command ID`, `beamenu --list-commands` — with `--daemon` now
  running the full daemon and the other two preferring it when it is up.

- [ ] **Step 1: Add a client helper to `rust/beamenu/src/ipc.rs`**

```rust
/// Call one method on a running daemon.
///
/// Returns `Err` for every reason a call might not land — no session bus, no
/// daemon owning the name, a method error — because the caller treats them
/// identically: do the work in-process instead. The distinction only matters
/// for the message, and a keybind has nowhere to print one.
///
/// # Errors
/// Fails when the bus, the name, or the call itself is unavailable.
pub fn call(method: &str, arg: Option<&str>) -> zbus::Result<()> {
    let connection = zbus::blocking::Connection::session()?;
    let proxy = zbus::blocking::Proxy::new(
        &connection,
        BUS_NAME,
        OBJECT_PATH,
        "dev.dots.Beamenu1",
    )?;
    match arg {
        Some(value) => proxy.call::<_, _, ()>(method, &(value,)),
        None => proxy.call::<_, _, ()>(method, &()),
    }
}
```

Add a test for it in `rust/beamenu/tests/ipc.rs`:

```rust
#[test]
fn calling_with_no_daemon_is_an_error_the_caller_can_fall_back_from() {
    // Either there is no session bus in this environment, or there is one and
    // nobody owns the name. Both are the same answer to the caller.
    assert!(beamenu::ipc::call("Show", None).is_err());
}
```

If the developer running the suite happens to have a real beamenu daemon on
their session bus, this test would open a panel — guard it by pointing the
call at a bus address that cannot resolve:
`std::env::set_var("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent")` at
the top of the test, and note that `set_var` is `unsafe` in edition 2024 but
this crate is edition 2021 (`rust/beamenu/Cargo.toml:4`), so it is a plain
call here. Because environment mutation is process-global, this test must be
the only one in the file that touches it.

- [ ] **Step 2: Rewrite the module docs and `run`**

Module docs, replacing `rust/beamenu/src/main.rs:1-9`:

```rust
//! beamenu's entry point.
//!
//! Four modes, and one rule that shapes them: whatever the daemon can do,
//! this binary must still do on its own. A machine where the user never
//! enabled the service, a session where it crashed, a login before the unit
//! started — the keybind has to open a launcher in all of them. So
//! `--command` and the no-argument launcher try the session bus first and
//! fall back to doing the work in-process, and nothing here treats a missing
//! daemon as an error.
//!
//! Exit codes matter because a keybind is the usual caller and has no
//! terminal to read a message from: 0 for done, 1 for a real failure, 2 for a
//! usage error. Diagnostics go to stderr so `--list-commands` stays pipeable.
```

`--daemon`'s help text becomes:

```rust
    /// Run the resident daemon: launcher host, D-Bus interface and clipboard
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

    if let Some(id) = &cli.command {
        if ipc::call("RunCommand", Some(id)).is_ok() {
            return Ok(ExitCode::SUCCESS);
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

    if ipc::call("Show", None).is_ok() {
        return Ok(ExitCode::SUCCESS);
    }

    let mut app = App::new();
    beamenu::run(&mut app)?;
    Ok(ExitCode::SUCCESS)
```

Note the deliberate asymmetry: an unknown id reaching a live daemon comes back
as a call error, so it falls through to the local path, which then prints the
usage message and exits 2. The user-visible behaviour is identical whether or
not a daemon is running, which is the property worth keeping.

Update the `use` line to bring in `ipc`.

- [ ] **Step 3: Verify it builds and the whole suite still passes**

`cargo build && cargo test` (with the `BMV` prefix). Expected: clean.

- [ ] **Step 4: Verify the argv surface by hand** (no display needed)

```bash
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent target/debug/beamenu --list-commands | head -3
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent target/debug/beamenu --command definitely-not-a-command; echo "exit=$?"
```

Expected: ids printed; then the unknown-command message and `exit=2`.

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/main.rs rust/beamenu/src/ipc.rs rust/beamenu/tests/ipc.rs
git commit -m "feat(beamenu): prefer the daemon over the bus, fall back to running in-process"
```

---

### Task 7: the systemd user unit

**Files:**
- Modify: `nix/home/beamenu.nix` (the `systemd.user.services.beamenu-clipboard`
  block)

**Interfaces:**
- Consumes: Task 6's `beamenu --daemon`, Task 4's `dev.dots.Beamenu`.
- Produces: `systemd.user.services.beamenu` replacing
  `systemd.user.services.beamenu-clipboard`.

- [ ] **Step 1: Read the existing unit**, including the
`lib.mkIf cfg.clipboardHistory` gate around it and the `clipboardHistory`
option's description. Note that other agents have edited this file recently:
re-read it rather than working from memory.

- [ ] **Step 2: Replace it**

```nix
    # One resident process now, not one per keypress. It holds the desktop
    # entry index warm, owns the launcher's Wayland connection, exports
    # dev.dots.Beamenu1 on the session bus, and runs the clipboard watcher
    # that used to be its own unit.
    #
    # Type=dbus rather than simple: the well-known name appearing IS the
    # readiness signal, so anything ordered after this unit can rely on the
    # launcher actually answering rather than merely having been exec'd.
    systemd.user.services.beamenu = {
      Unit = {
        Description = "beamenu launcher daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        Type = "dbus";
        BusName = "dev.dots.Beamenu";
        ExecStart = "${lib.getExe beamenuPkg} --daemon";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
```

Keep whatever `lib.getExe`-vs-`${beamenuPkg}/bin/beamenu` form the file
already uses. Drop the `clipboardHistory` gate from the unit — the daemon is
now wanted whether or not clipboard history is on. If `clipboardHistory` gated
anything else, leave that alone; if it now only gates the `clipboard`
provider, say so in your report so its description can be revisited.

- [ ] **Step 3: Eval-check**

```bash
cd /home/matus/Dokumente/codeberg/personal/dots
host=tokyonight   # named, not discovered: the first attr is live-iso, which has no Home Manager
nix eval --impure ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath"
user=matus
nix eval --impure ".#nixosConfigurations.$host.config.home-manager.users.$user.systemd.user.services" --apply 'builtins.attrNames'
```

Expected: evaluates clean; `beamenu` present and `beamenu-clipboard` absent.

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

- [ ] **Step 2: Start a private session bus and a nested compositor**

The daemon must not land on the user's real session bus, where it would take
the `dev.dots.Beamenu` name from whatever is running and steal keyboard focus
on the live screen. Give it both a private bus and a nested display:

```bash
SCRATCH=/tmp/claude-1000/-home-matus-Dokumente-codeberg-personal-dots/59ef0e92-f17d-45dc-a9bb-ea295026e5cd/scratchpad
cat > "$SCRATCH/hypr-soak.conf" <<'EOF'
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
animations { enabled = false }
EOF
eval "$(dbus-launch --sh-syntax)"       # exports DBUS_SESSION_BUS_ADDRESS + PID
echo "private bus: $DBUS_SESSION_BUS_ADDRESS"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
  Hyprland --config "$SCRATCH/hypr-soak.conf" > "$SCRATCH/hypr-soak.log" 2>&1 &
sleep 3
grep -o 'wayland-[0-9]*' "$SCRATCH/hypr-soak.log" | head -1
```

Everything below runs in that same shell so it inherits the private bus.

- [ ] **Step 3: Run the daemon inside it**

```bash
WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu --daemon &
sleep 2
```

- [ ] **Step 4: Prove the interface is on the bus**

```bash
busctl --user list | grep dev.dots.Beamenu
busctl --user introspect dev.dots.Beamenu /dev/dots/Beamenu
busctl --user get-property dev.dots.Beamenu /dev/dots/Beamenu dev.dots.Beamenu1 Apps
```

Expected: the name is owned; introspection lists `Show`, `RunCommand`,
`Reload` and the four properties; `Apps` is non-zero.

- [ ] **Step 5: Show the launcher repeatedly**

```bash
for i in 1 2 3 4 5; do
  WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu
  sleep 1
  WAYLAND_DISPLAY=<nested> grim "$SCRATCH/show-$i.png"
  WAYLAND_DISPLAY=<nested> hyprctl dispatch sendshortcut ",Escape,"
  sleep 1
done
```

Expected: five screenshots each showing the panel, the daemon alive between
them, and RSS not climbing round over round (`grep VmRSS /proc/<pid>/status`
before and after).

- [ ] **Step 6: Prove idempotent Show and the property**

```bash
WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu &   # opens the panel
sleep 1
busctl --user get-property dev.dots.Beamenu /dev/dots/Beamenu dev.dots.Beamenu1 Visible
WAYLAND_DISPLAY=<nested> <store-path>/bin/beamenu     # must return at once
WAYLAND_DISPLAY=<nested> hyprctl dispatch sendshortcut ",Escape,"
```

Expected: `Visible` reads `b true` while up; the second invocation exits
immediately without stacking a second panel.

- [ ] **Step 7: Prove the fallback**

```bash
pkill -f 'beamenu --daemon'
sleep 1
DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent WAYLAND_DISPLAY=<nested> \
  timeout 5 <store-path>/bin/beamenu
```

With no bus at all, this must still open the panel (screenshot it) rather
than exit immediately.

- [ ] **Step 8: Tear down**

```bash
pkill -f 'beamenu --daemon'
pkill -f 'Hyprland --config .*hypr-soak.conf'
kill "$DBUS_SESSION_BUS_PID"
```

- [ ] **Step 9: Report** — the screenshots' paths, the introspection output,
the `Apps`/`Visible` readings, and the RSS numbers. No commit.
