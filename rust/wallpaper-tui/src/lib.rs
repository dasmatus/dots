//! `wallpaper-tui` — awww-based TUI wallpaper changer with
//! wallpaper-derived accent tinting. The binary (`main.rs`) is a thin
//! terminal loop; everything testable lives here and is exercised by the
//! integration tests in `tests/`.

pub mod accent;
pub mod app;
pub mod awww;
pub mod cli;
pub mod config;
pub mod fx;
pub mod input;
pub mod preview;
pub mod tint;
pub mod ui;
pub mod wallpapers;
