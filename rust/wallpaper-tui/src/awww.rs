//! The `awww` backend: swaybg-mode mapping, the pure argv builder, and the
//! apply orchestrator.
//!
//! This replaces the `hyprtile-wallpaperd` backend, and most of that module
//! was machinery working around a daemon with no IPC. Changing the wallpaper
//! there meant SIGTERM-ing the running instance, polling `/proc` until its
//! pidfile flock was released, and spawning a replacement. awww takes an
//! `awww img` request over a socket, so the pidfile, the process table and
//! the stop-then-spawn dance are all gone.
//!
//! Two capabilities come back with it. awww accepts `--outputs`, so the
//! per-output data model in `config.rs` is finally representable end to end
//! rather than collapsing to "whatever the first group said". And it has
//! transitions, which retired along with the awww daemon.

use std::process::{Command, Stdio};
use std::time::Duration;

use crate::config::Effective;

/// How long to wait for a freshly spawned `awww-daemon` to answer.
const DAEMON_WAIT: Duration = Duration::from_millis(2000);
/// Poll interval while waiting for that daemon.
const DAEMON_POLL: Duration = Duration::from_millis(25);

/// Map a swaybg-derived scaling mode to a `awww img --resize` value.
///
/// awww has no `tile`; it degrades to `crop`, the same choice
/// `hyprtile-wallpaperd`'s backend made. Unknown modes default to `crop`.
#[must_use]
pub fn map_mode(mode: &str) -> &'static str {
    match mode {
        "fit" => "fit",
        "stretch" => "stretch",
        "center" => "no",
        _ => "crop",
    }
}

/// One output's resolved wallpaper.
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

/// How a wallpaper change is animated.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    /// A `awww img --transition-type` value.
    pub kind: String,
    /// Duration in seconds, passed as `--transition-duration`.
    pub duration: String,
    /// Frames per second, passed as `--transition-fps`.
    pub fps: String,
}

impl Default for Transition {
    fn default() -> Self {
        Self {
            kind: "fade".to_string(),
            duration: "1".to_string(),
            fps: "60".to_string(),
        }
    }
}

impl Transition {
    /// Read the transition the declarative config asked for.
    #[must_use]
    pub fn from_config(config: &crate::config::Config) -> Self {
        Self {
            kind: config.transition.clone(),
            duration: config.transition_duration.clone(),
            fps: config.transition_fps.clone(),
        }
    }
}

/// Build the argv for one `awww img` invocation.
///
/// `--fill-color` is only meaningful for modes that leave bars, but awww
/// accepts it unconditionally, so it is always passed rather than branched on.
#[must_use]
pub fn awww_args(group: &Group, transition: &Transition) -> Vec<String> {
    vec![
        "awww".to_string(),
        "img".to_string(),
        group.path.clone(),
        "--outputs".to_string(),
        group.output.clone(),
        "--resize".to_string(),
        map_mode(&group.mode).to_string(),
        "--fill-color".to_string(),
        // awww wants RRGGBBAA with no leading hash; the config stores CSS-style
        // "#RRGGBB" because that is what every other colour option here uses.
        group.fill_color.trim_start_matches('#').to_string(),
        "--transition-type".to_string(),
        transition.kind.clone(),
        "--transition-duration".to_string(),
        transition.duration.clone(),
        "--transition-fps".to_string(),
        transition.fps.clone(),
    ]
}

/// Indirection over process control so the orchestrator is unit-testable
/// without a running compositor: the live backend shells out, the test
/// backend records the argv it was handed.
pub trait AwwwBackend {
    /// `true` when `awww query` succeeds, meaning the daemon is up.
    fn daemon_running(&self) -> bool;
    /// Spawn `awww-daemon` detached. Reports whether the spawn syscall
    /// succeeded, not whether the daemon came up.
    fn spawn_daemon(&self) -> bool;
    /// Run one command to completion, reporting whether it exited zero.
    fn run(&self, argv: &[String]) -> bool;
}

pub struct LiveAwww;

extern "C" {
    fn setsid() -> i32;
}

impl AwwwBackend for LiveAwww {
    fn daemon_running(&self) -> bool {
        Command::new("awww")
            .arg("query")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    fn spawn_daemon(&self) -> bool {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new("awww-daemon");
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: setsid() is async-signal-safe and takes no arguments; it runs
        // in the forked child before exec, detaching the daemon so it outlives
        // this process.
        unsafe {
            cmd.pre_exec(|| {
                setsid();
                Ok(())
            });
        }
        cmd.spawn().is_ok()
    }

    fn run(&self, argv: &[String]) -> bool {
        Command::new(&argv[0])
            .args(&argv[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}

/// Make sure a daemon is answering, spawning one if not.
///
/// `awww img` fails outright when no daemon is listening, and the daemon takes
/// a moment to bind its socket, so a fresh spawn is polled rather than assumed.
pub fn ensure_daemon<B: AwwwBackend>(backend: &B, wait: Duration, poll: Duration) -> bool {
    if backend.daemon_running() {
        return true;
    }
    if !backend.spawn_daemon() {
        return false;
    }

    let deadline = std::time::Instant::now() + wait;
    while std::time::Instant::now() < deadline {
        if backend.daemon_running() {
            return true;
        }
        std::thread::sleep(poll);
    }
    false
}

/// Apply every group, one `awww img` per output.
///
/// Unlike the `hyprtile-wallpaperd` backend this does not collapse to the
/// first group: awww targets outputs individually, so several distinct
/// per-output wallpapers are representable again. Reports whether every group
/// applied; a partial failure still leaves the successful outputs changed.
pub fn apply_wallpaper<B: AwwwBackend>(
    backend: &B,
    groups: &[Group],
    transition: &Transition,
) -> bool {
    if groups.is_empty() {
        return false;
    }
    if !ensure_daemon(backend, DAEMON_WAIT, DAEMON_POLL) {
        return false;
    }

    // `.all()` short-circuits and would skip `backend.run` for groups after
    // the first failure, contradicting the "partial failure still leaves the
    // successful outputs changed" contract above.
    #[allow(clippy::unnecessary_fold)]
    groups
        .iter()
        .map(|group| backend.run(&awww_args(group, transition)))
        .fold(true, |all, ok| all && ok)
}

/// Resolve every configured output into a group, skipping outputs whose
/// wallpaper is unset or missing on disk.
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
