//! dots-snip — Snipping Tool-style screenshot overlay for Hyprland.
//!
//! A fullscreen transparent Tauri window carries the selection UI; the dim
//! frosting is the global Hyprland `decoration.blur` showing through the
//! overlay's per-pixel alpha on the live desktop behind it (there is no
//! per-window `blur` rule in Hyprland's Lua DSL — only `no_blur`), not image
//! processing. On confirm the window is hidden and `grim -g` captures the
//! selected region (now unobscured) to a file and the Wayland clipboard.

use dots_snip::{capture as cap, geometry};
use tauri::{Manager, WebviewWindow};

// Tauri's #[command] macro injects WebviewWindow by value (owned handle), so
// clippy::needless_pass_by_value is unavoidable — allow it on both commands.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn capture(window: WebviewWindow, rect: geometry::Rect) {
    let app = window.app_handle().clone();
    let _ = window.hide();
    std::thread::sleep(std::time::Duration::from_millis(80));

    let geo = geometry::to_global(rect, cap::focused_monitor());
    if geo.w <= 0 || geo.h <= 0 {
        app.exit(0);
        return;
    }
    if let Err(e) = cap::run(&geo) {
        eprintln!("dots-snip: {e:#}");
    }
    app.exit(0);
}

/// Invoked from the frontend on Esc / empty selection — exit without capture.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn cancel(window: WebviewWindow) {
    window.app_handle().exit(0);
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![capture, cancel])
        .run(tauri::generate_context!())
        .expect("error while running dots-snip");
}
