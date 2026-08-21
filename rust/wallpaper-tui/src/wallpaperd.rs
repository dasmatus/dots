//! The `hyprtile-wallpaperd` backend: swaybg-mode → `--mode` mapping, the
//! pure argv builder, the stop-old/spawn-new apply orchestrator, and the
//! best-effort `~/.hyprtile/config.json` sync.
//!
//! Unlike the awww daemon it replaces, `hyprtile-wallpaperd` renders on
//! *every* output at once (wlr-layer-shell, no `-o`/per-output targeting) and
//! is not IPC-controlled — there is no persistent daemon you send an "apply"
//! message to. Changing the wallpaper means killing the running instance and
//! spawning a fresh one with the new `--image`/`--mode`. It also `flock()`s
//! its pidfile and refuses to start while the lock is held, so the caller
//! must stop the previous instance first (SIGTERM + a short wait) before
//! spawning a replacement.
//!
//! The config/state data model stays per-output (`Config`/`State` in
//! `config.rs`, and the [`Group`]s built here) so the picker UI keeps letting
//! you pick "which output's declared wallpaper" to edit — but only the
//! *first* resolved `Group` handed to [`apply_wallpaper`] is ever actually
//! rendered, since one `hyprtile-wallpaperd` instance paints every screen.
//! Restoring several distinct per-output wallpapers is therefore not
//! representable; `restore` re-applies the first output's effective
//! wallpaper globally instead.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::config::Effective;

extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn setsid() -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
}

/// `SIGTERM` — no `libc` dependency for one constant.
const SIGTERM: i32 = 15;
/// `WNOHANG` for [`waitpid`] — same no-`libc` rationale as [`SIGTERM`].
const WNOHANG: i32 = 1;

/// Poll interval while waiting for the previous `hyprtile-wallpaperd` to
/// exit after `SIGTERM`.
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(20);
/// Total time to wait for the previous instance to exit before giving up and
/// spawning the replacement anyway (best-effort, mirrors the flock retrying
/// on its own if the old process is merely slow to die).
const STOP_WAIT_TIMEOUT: Duration = Duration::from_millis(500);

/// Map a swaybg-derived scaling mode to a `hyprtile-wallpaperd --mode` value.
/// wallpaperd has no `tile`; it degrades to `cover` (same as `fill`) rather
/// than the awww-era centered degrade. Unknown modes default to `cover`.
#[must_use]
pub fn map_mode(mode: &str) -> &'static str {
    match mode {
        "fit" => "contain",
        "stretch" => "stretch",
        "center" => "center",
        _ => "cover",
    }
}

/// One apply group: the output name (informational only — wallpaperd has no
/// per-output targeting, see the module docs) and the effective
/// `path/mode/fill_color` to apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
    pub output: String,
    pub path: String,
    pub mode: String,
    pub fill_color: String,
}

impl Group {
    #[must_use]
    pub fn from_effective(output: &str, eff: &Effective) -> Self {
        Self {
            output: output.to_string(),
            path: eff.path.clone(),
            mode: eff.mode.clone(),
            fill_color: eff.fill_color.clone(),
        }
    }
}

/// Build the argv for one `hyprtile-wallpaperd` invocation.
#[must_use]
pub fn wallpaperd_args(path: &str, mode: &str, pidfile: &Path) -> Vec<String> {
    vec![
        "hyprtile-wallpaperd".to_string(),
        "--image".to_string(),
        path.to_string(),
        "--mode".to_string(),
        map_mode(mode).to_string(),
        "--pidfile".to_string(),
        pidfile.to_string_lossy().into_owned(),
    ]
}

/// Indirection over process control so the orchestrator is unit-testable
/// without a real daemon: a live backend signals/spawns for real, the test
/// backend records calls against an in-memory fake process table.
pub trait WallpaperdBackend {
    /// `true` if a process with this pid is currently alive.
    fn is_alive(&self, pid: i32) -> bool;
    /// Send `SIGTERM` to `pid`. Best-effort — never panics.
    fn terminate(&self, pid: i32);
    /// Spawn one detached `hyprtile-wallpaperd` invocation from `argv`.
    /// Returns whether the spawn syscall itself succeeded (not whether the
    /// daemon stays up).
    fn spawn(&self, argv: &[String]) -> bool;
}

/// Live backend that actually signals and spawns processes.
pub struct LiveWallpaperd;

impl WallpaperdBackend for LiveWallpaperd {
    fn is_alive(&self, pid: i32) -> bool {
        // Daemons spawned by THIS process stay zombies after SIGTERM until
        // reaped (nobody wait()s on the dropped Child), which would keep
        // /proc/<pid> alive for the whole stop timeout on every same-session
        // re-apply. Reap opportunistically first: for our own dead children
        // waitpid(WNOHANG) clears the zombie; for foreign pids it fails with
        // ECHILD, which is exactly the "not ours, judge by /proc" case.
        // SAFETY: waitpid with WNOHANG and a null status pointer never
        // blocks and has no memory requirements; failures are ignored by
        // contract (best-effort reap).
        unsafe {
            waitpid(pid, std::ptr::null_mut(), WNOHANG);
        }
        is_pid_alive(pid)
    }

    fn terminate(&self, pid: i32) {
        // SAFETY: `kill(2)` with a plain pid/signal pair has no aliasing or
        // lifetime requirements; the return value (an error code) is
        // deliberately ignored — this is best-effort by contract.
        unsafe {
            kill(pid, SIGTERM);
        }
    }

    fn spawn(&self, argv: &[String]) -> bool {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new(&argv[0]);
        cmd.args(&argv[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: `setsid()` is async-signal-safe and takes no arguments; it
        // runs in the forked child before exec, detaching it into its own
        // session so it outlives this process's controlling terminal (and
        // process group) once the TUI exits.
        unsafe {
            cmd.pre_exec(|| {
                setsid();
                Ok(())
            });
        }
        cmd.spawn().is_ok()
    }
}

/// `true` iff a process with this pid currently exists (`/proc/<pid>`) and
/// is not a zombie — an unreaped exited child still has a `/proc` entry but
/// is dead for every purpose that matters here (its pidfile flock is
/// released at exit, before reaping).
#[must_use]
pub fn is_pid_alive(pid: i32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(stat) => proc_stat_alive(&stat),
        Err(_) => false,
    }
}

/// Parse a `/proc/<pid>/stat` line's process-state field (the first
/// non-space character after the *last* `)` — the comm field may itself
/// contain parentheses) and report liveness: `Z` (zombie) and `X`/`x`
/// (dead) are not alive; every other state (or an unparseable line,
/// conservatively) is.
#[must_use]
pub fn proc_stat_alive(stat: &str) -> bool {
    let Some(after_comm) = stat.rfind(')').map(|i| &stat[i + 1..]) else {
        return true;
    };
    !matches!(
        after_comm.trim_start().chars().next(),
        Some('Z' | 'X' | 'x')
    )
}

/// Read and parse a pidfile's contents as a PID. Missing file, empty, or
/// non-numeric content all map to `None`.
#[must_use]
pub fn read_pid(pidfile: &Path) -> Option<i32> {
    std::fs::read_to_string(pidfile).ok()?.trim().parse().ok()
}

/// Canonical `hyprtile-wallpaperd` pidfile — shared with the `hyprtile`
/// launcher, which auto-spawns the daemon at its own startup only if this
/// PID is not alive.
#[must_use]
pub fn pidfile_path() -> PathBuf {
    crate::config::home_dir()
        .join(".hyprtile")
        .join("wallpaperd.pid")
}

/// `~/.hyprtile/config.json` — the `hyprtile` launcher's own config, kept in
/// sync (best-effort) after a successful apply so the launcher's next
/// auto-spawn picks up the same wallpaper.
#[must_use]
pub fn hyprtile_config_path() -> PathBuf {
    crate::config::home_dir()
        .join(".hyprtile")
        .join("config.json")
}

/// Stop the previous `hyprtile-wallpaperd` (if any) so a fresh spawn can take
/// the pidfile's `flock()`. Reads `pidfile`; if the recorded PID is alive,
/// sends `SIGTERM` and polls (every `poll`, up to `timeout`) for it to exit.
/// Best-effort: a PID that refuses to die within `timeout` is left alone and
/// the caller proceeds to spawn anyway — never raises.
pub fn stop_old_daemon<B: WallpaperdBackend>(
    backend: &B,
    pidfile: &Path,
    poll: Duration,
    timeout: Duration,
) {
    let Some(pid) = read_pid(pidfile) else {
        return;
    };
    if !backend.is_alive(pid) {
        return;
    }
    backend.terminate(pid);
    let deadline = Instant::now() + timeout;
    while backend.is_alive(pid) && Instant::now() < deadline {
        std::thread::sleep(poll);
    }
}

/// Apply one wallpaper globally: stop the previous `hyprtile-wallpaperd` (via
/// `pidfile`) and spawn a replacement rendering `groups.first()`'s
/// path/mode on every output. Only the first group is meaningful —
/// wallpaperd has no per-output targeting, see the module docs. Returns
/// whether a replacement was spawned: `false` for empty `groups`, a failed
/// spawn syscall, or a previous daemon that outlived the stop timeout — in
/// that last case the replacement would lose the pidfile `flock()` race and
/// silently exit, so refusing (and letting the caller skip the config sync)
/// beats reporting a wallpaper that never rendered.
pub fn apply_wallpaper<B: WallpaperdBackend>(
    backend: &B,
    groups: &[Group],
    pidfile: &Path,
) -> bool {
    let Some(g) = groups.first() else {
        return false;
    };
    stop_old_daemon(backend, pidfile, STOP_POLL_INTERVAL, STOP_WAIT_TIMEOUT);
    if let Some(pid) = read_pid(pidfile) {
        if backend.is_alive(pid) {
            return false;
        }
    }
    let argv = wallpaperd_args(&g.path, &g.mode, pidfile);
    backend.spawn(&argv)
}

/// Merge `"wallpaper": 1`, `"wallpaper_file": path`, `"wallpaper_mode": mode`
/// into the parsed hyprtile `config.json` document, preserving every other
/// key. `mode` should already be a `hyprtile-wallpaperd --mode` value (see
/// [`map_mode`]), matching what the `hyprtile` launcher itself writes. A
/// non-object document is returned unchanged (defensive — the launcher's
/// config is always an object in practice).
#[must_use]
pub fn merge_hyprtile_config(
    mut doc: serde_json::Value,
    path: &str,
    mode: &str,
) -> serde_json::Value {
    if let Some(obj) = doc.as_object_mut() {
        obj.insert("wallpaper".to_string(), serde_json::Value::from(1));
        obj.insert("wallpaper_file".to_string(), serde_json::Value::from(path));
        obj.insert("wallpaper_mode".to_string(), serde_json::Value::from(mode));
    }
    doc
}

/// Best-effort sync of `~/.hyprtile/config.json` after a successful apply:
/// round-trips the document through [`merge_hyprtile_config`] (mapping
/// `mode` via [`map_mode`] first) so every other key survives. A missing
/// file is skipped silently (the `hyprtile` launcher may not be installed);
/// a malformed file is left untouched rather than clobbered.
pub fn sync_hyprtile_config(config_path: &Path, path: &str, mode: &str) {
    let Ok(text) = std::fs::read_to_string(config_path) else {
        return;
    };
    let Ok(doc) = serde_json::from_str::<serde_json::Value>(&text) else {
        return;
    };
    let merged = merge_hyprtile_config(doc, path, map_mode(mode));
    let Ok(mut out) = serde_json::to_string_pretty(&merged) else {
        return;
    };
    out.push('\n');
    let _ = std::fs::write(config_path, out);
}

/// Build the groups for a full restore: every declared output whose effective
/// path still exists. Only the first is ever actually rendered by
/// [`apply_wallpaper`] (see the module docs), but the full per-output set is
/// still built so state/config stay consistent and future backends with
/// real per-output support can use it unchanged.
#[must_use]
pub fn restore_groups(config: &crate::config::Config, state: &crate::config::State) -> Vec<Group> {
    let mut groups = Vec::new();
    for output in config.outputs.keys() {
        let eff = crate::config::effective_output(config, state, output);
        if !eff.path.is_empty() && path_exists(&eff.path) {
            groups.push(Group::from_effective(output, &eff));
        }
    }
    groups
}

fn path_exists(p: &str) -> bool {
    std::path::Path::new(p).exists()
}
