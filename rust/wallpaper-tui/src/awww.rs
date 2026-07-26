//! The awww backend: mode/fill-color mapping, the pure ``awww img`` argv
//! builder, the apply orchestrator, and a defensive daemon-ensure.
//!
//! awww is IPC-driven: one persistent ``awww-daemon`` holds the wallpaper, so
//! (unlike swaybg) there is no kill+respawn per apply. ``awww`` has no ``init``
//! subcommand (unlike swww) — start the daemon via ``awww-daemon``.

use std::process::Command;
use std::time::Duration;

use crate::config::Effective;

/// Map a swaybg scaling mode to an awww ``--resize`` value. awww has no
/// ``tile`` (degrades to centered ``no``); it supports ``stretch`` directly.
/// Unknown modes default to ``crop`` (fill).
#[must_use]
pub fn map_resize(mode: &str) -> &'static str {
    match mode {
        "fill" => "crop",
        "stretch" => "stretch",
        "fit" => "fit",
        "center" => "no",
        "tile" => "no",
        _ => "crop",
    }
}

/// Normalize a ``#rrggbb``/``rrggbb``/``#rrggbbaa`` fill color to bare
/// ``RRGGBBAA``. awww's ``--fill-color`` is 8-digit RGBA (default
/// ``000000ff``), no leading ``#``. Empty input falls back to opaque black.
#[must_use]
pub fn normalize_fill_color(color: &str) -> String {
    let c = color.trim_start_matches('#');
    if c.is_empty() {
        return "000000ff".to_string();
    }
    if c.len() == 6 {
        return format!("{c}ff");
    }
    c.to_ascii_lowercase()
}

/// One apply group: the output name (or ``"*"`` for all-outputs) and the
/// effective `path/mode/fill_color` to apply.
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

/// Build the argv for one ``awww img`` IPC command. ``-o`` is omitted for the
/// ``*``/all-outputs case (awww has no ``*``; an empty ``--outputs`` list means
/// all outputs). ``fill_color`` is normalized to ``RRGGBBAA``.
#[must_use]
pub fn awww_img_args(
    group: &Group,
    transition_type: &str,
    transition_duration: f64,
) -> Vec<String> {
    let mut args = vec!["awww".to_string(), "img".to_string()];
    if !group.output.is_empty() && group.output != "*" {
        args.push("-o".to_string());
        args.push(group.output.clone());
    }
    args.push(group.path.clone());
    args.push("--resize".to_string());
    args.push(map_resize(&group.mode).to_string());
    args.push("--fill-color".to_string());
    args.push(normalize_fill_color(&group.fill_color));
    args.push("--transition-type".to_string());
    args.push(transition_type.to_string());
    args.push("--transition-duration".to_string());
    args.push(format_transition_duration(transition_duration));
    args
}

/// Format the duration the way the Python ``str(1.0)`` did: ``1.0``, ``2.0``,
/// never ``1`` (awww parses a float; keep the ``.0``).
fn format_transition_duration(d: f64) -> String {
    if d.fract() == 0.0 {
        format!("{d:.1}")
    } else {
        format!("{d}")
    }
}

/// Indirection over the ``awww`` CLI so the orchestrator is unit-testable
/// without a real daemon: a live backend shells out, the test backend
/// records argv.
pub trait AwwwBackend {
    /// Returns `true` if `awww query` succeeds (daemon up).
    fn query(&self) -> bool;
    /// Spawn one ``awww img`` client. Returns the captured argv (live impl
    /// returns the argv it spawned; test impl records it).
    fn spawn_img(&self, argv: &[String]);
}

/// Live backend that actually shells out to ``awww``.
pub struct LiveAwww;

impl AwwwBackend for LiveAwww {
    fn query(&self) -> bool {
        Command::new("awww")
            .arg("query")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    fn spawn_img(&self, argv: &[String]) {
        let _ = Command::new(&argv[0])
            .args(&argv[1..])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
}

/// Best-effort: make sure ``awww-daemon`` is running before sending img IPC.
/// ``awww query`` returns nonzero if the daemon is down; in that case spawn
/// ``awww-daemon`` detached and give it a moment. Never raises.
pub fn ensure_daemon<B: AwwwBackend>(backend: &B) {
    if backend.query() {
        return;
    }
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new("awww-daemon");
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .process_group(0);
    let _ = cmd.spawn();
    std::thread::sleep(Duration::from_millis(300));
}

/// Apply `groups` via the awww daemon (one ``awww img`` per output). Returns
/// the number of spawned clients. Empty input is a no-op.
pub fn apply_wallpaper<B: AwwwBackend>(
    backend: &B,
    groups: &[Group],
    transition_type: &str,
    transition_duration: f64,
) -> usize {
    if groups.is_empty() {
        return 0;
    }
    ensure_daemon(backend);
    for g in groups {
        let argv = awww_img_args(g, transition_type, transition_duration);
        backend.spawn_img(&argv);
    }
    groups.len()
}

/// Build the groups for a full restore: every declared output whose effective
/// path still exists.
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
