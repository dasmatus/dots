//! awww backend: mode mapping, fill-color normalization, argv building, and
//! the apply_wallpaper orchestrator (backend stubbed). Ports
//! ``test_awww_backend.py``.

mod common;

use std::sync::Mutex;

use wallpaper_tui::awww::{
    apply_wallpaper, awww_img_args, map_resize, normalize_fill_color, AwwwBackend, Group,
};

#[derive(Default)]
struct FakeBackend {
    /// `query` returns `true` (daemon already up) so no daemon spawn is attempted.
    up: bool,
    spawns: Mutex<Vec<Vec<String>>>,
}

impl AwwwBackend for FakeBackend {
    fn query(&self) -> bool {
        self.up
    }
    fn spawn_img(&self, argv: &[String]) {
        self.spawns.lock().unwrap().push(argv.to_vec());
    }
}

#[test]
fn map_resize_swaybg_to_awww() {
    assert_eq!(map_resize("fill"), "crop");
    assert_eq!(map_resize("stretch"), "stretch");
    assert_eq!(map_resize("fit"), "fit");
    assert_eq!(map_resize("center"), "no");
    assert_eq!(map_resize("tile"), "no", "tile unsupported -> centered");
    assert_eq!(map_resize("unknown"), "crop", "unknown -> crop default");
}

#[test]
fn normalize_fill_color_variants() {
    assert_eq!(normalize_fill_color("#d2a1a1"), "d2a1a1ff");
    assert_eq!(normalize_fill_color("d2a1a1"), "d2a1a1ff");
    assert_eq!(normalize_fill_color("#000000ff"), "000000ff");
    assert_eq!(
        normalize_fill_color(""),
        "000000ff",
        "empty -> opaque black"
    );
}

fn group(output: &str, path: &str, mode: &str, fill_color: &str) -> Group {
    Group {
        output: output.to_string(),
        path: path.to_string(),
        mode: mode.to_string(),
        fill_color: fill_color.to_string(),
    }
}

fn idx<'a>(args: &'a [String], flag: &str) -> &'a str {
    let i = args.iter().position(|a| a == flag).expect(flag);
    &args[i + 1]
}

#[test]
fn awww_img_args_single_output() {
    let g = group("eDP-1", "/w/p.jpg", "fit", "#d2a1a1");
    let args = awww_img_args(&g, "grow", 1.0);
    assert_eq!(
        &args[0..3],
        &["awww".to_string(), "img".to_string(), "-o".to_string()]
    );
    assert_eq!(args[3], "eDP-1");
    assert!(args.contains(&"/w/p.jpg".to_string()));
    assert_eq!(idx(&args, "--resize"), "fit");
    assert_eq!(idx(&args, "--fill-color"), "d2a1a1ff");
    assert_eq!(idx(&args, "--transition-type"), "grow");
    assert_eq!(idx(&args, "--transition-duration"), "1.0");
}

#[test]
fn awww_img_args_star_output_omits_o() {
    let g = group("*", "/w/p.jpg", "fill", "#000000");
    let args = awww_img_args(&g, "fade", 2.0);
    assert!(!args.contains(&"-o".to_string()));
    assert!(!args.contains(&"--outputs".to_string()));
    assert!(args.contains(&"/w/p.jpg".to_string()));
}

#[test]
fn apply_wallpaper_spawns_one_img_per_group() {
    let backend = FakeBackend {
        up: true,
        spawns: Mutex::new(Vec::new()),
    };
    let groups = [
        group("eDP-1", "/w/a.jpg", "fill", "#000000"),
        group("HDMI-1", "/w/b.jpg", "fit", "#d2a1a1"),
    ];
    let n = apply_wallpaper(&backend, &groups, "grow", 1.0);
    assert_eq!(n, 2);
    let spawns = backend.spawns.lock().unwrap().clone();
    assert_eq!(spawns.len(), 2);
    // Pin the integration: apply_wallpaper must pass awww_img_args's full argv
    // (mode mapping, fill-color, transition flags) through to spawn — not just
    // spawn N processes. Otherwise the orchestrator could silently drop flags
    // while the awww_img_args unit tests still pass in isolation.
    let expected: Vec<Vec<String>> = groups
        .iter()
        .map(|g| awww_img_args(g, "grow", 1.0))
        .collect();
    assert_eq!(spawns, expected);
    assert_eq!(spawns[0][0], "awww");
    assert_eq!(spawns[0][1], "img");
    assert_eq!(spawns[1][3], "HDMI-1");
}

#[test]
fn apply_wallpaper_empty_groups_noop() {
    let backend = FakeBackend {
        up: true,
        spawns: Mutex::new(Vec::new()),
    };
    assert_eq!(apply_wallpaper(&backend, &[], "grow", 1.0), 0);
    assert!(backend.spawns.lock().unwrap().is_empty());
}
