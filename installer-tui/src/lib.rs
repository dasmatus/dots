//! tokyonight-dots NixOS installer — library surface.
//!
//! The binary (`main.rs`) is a thin terminal loop; everything testable lives
//! here and is exercised by the integration tests in `tests/`.

pub mod app;
pub mod config;
pub mod disks;
pub mod install;
pub mod ui;
