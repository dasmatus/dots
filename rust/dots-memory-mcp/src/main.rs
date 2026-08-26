//! `dots-memory-mcp`: a stateless stdio MCP server exposing five memory
//! tools over the `agentmem` Postgres schema.
//!
//! Scaffolding stage: the connection pool and `MemoryStore` trait exist;
//! the tools themselves are wired in the next commit.

mod config;
mod store;

fn main() {
    let _pool_config = config::PgConfig::from_env();
}
