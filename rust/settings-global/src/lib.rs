//! Post-install settings editor for the dots flake: loads, edits and saves
//! the installer-written /var/lib/dots/settings.nix (see
//! rust/installer-tui/src/config.rs::settings_nix for the writer).

pub mod menu;
pub mod rpc;
pub mod settings;
