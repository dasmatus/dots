//! Library surface for `dots-memory-mcp`, split out from `main.rs` so
//! `tests/` can exercise the tool layer against a fake `MemoryStore`
//! without spawning the real binary.

pub mod config;
pub mod pgerr;
pub mod store;
pub mod tools;
