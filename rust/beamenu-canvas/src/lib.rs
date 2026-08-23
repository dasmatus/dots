//! Pure model for `beamenu-canvas`, the WebKitGTK sidecar that renders
//! beamenu plugin views under one host-enforced design system.
//!
//! Everything in this crate root is free of `gtk4`/`webkit6`/
//! `gtk4-layer-shell` — manifest parsing, the JSON-RPC protocol, component
//! validation, ANSI handling, markdown rendering and the design tokens are
//! all plain data and functions, which is what `tests/` exercises. The GTK
//! and WebKit glue (`window`, `worker`) lives only in the `beamenu-canvas`
//! binary (`src/main.rs` and its private modules), never in this lib.

pub mod ansi;
pub mod cli;
pub mod component;
pub mod config;
pub mod dispatch;
pub mod manifest;
pub mod markdown;
pub mod rpc;
pub mod shell;
pub mod theme;
