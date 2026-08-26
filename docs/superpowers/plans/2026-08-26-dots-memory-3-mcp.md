# Dots Memory MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** One stateless stdio MCP binary exposing five memory tools
over plan 2's SQL functions, with no server-side session or scope.
**Architecture:** an rmcp stdio server routes every call through a
`MemoryStore` trait to a pooled connection; each call carries scope.
**Tech Stack:** Rust, rmcp, tokio, tokio-postgres, deadpool-postgres,
schemars, `pkgs.rustPlatform.buildRustPackage`.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- Crate `rust/dots-memory-mcp`, binary `dots-memory-mcp`, edition 2021.
- Builds standalone; at runtime plans 0-2 must be live (socket,
  schema, functions) before any tool call can succeed.
- Vendor `rmcp` via Cargo.lock (nixpkgs has no MCP package). Open
  risk: rmcp is pre-1.0, pinned only by Cargo.lock like every crate.
- Connect as `PGUSER=agentmem_mcp` (plan 2's ident map), never `matus`.
- `tokio-postgres` ignores `PG*` env vars; read `PGHOST`,
  `PGDATABASE`, `PGOPTIONS` in code; set search_path via `options`.
- Function names and argument types are fixed in spec section 4.
- `unslop_token` is required, forwarded verbatim, never fabricated
  by the server, so raw fetched text fails the cleaning-pass gate.
- Retry SQLSTATE 40001 up to 3x, else a clean MCP error, never a
  panic; `ingest_fact` is one statement, so never a partial write.
- Tool map: recall to search, remember/forget to ingest_fact (forget
  fixes source_kind to "retraction"), graph to subgraph then
  edges_to_mermaid, session_note to cite_fact.

---
### Task 1: Scaffold the crate and the stateless store
**Files:** in `rust/dots-memory-mcp/`, create `Cargo.toml`,
`src/main.rs`, `src/config.rs`, `src/store.rs`; modify
`flake/packages.nix`.
**Produces:** binary `dots-memory-mcp`; `packages.dots-memory-mcp`;
trait `MemoryStore`, one async fn per mapped function;
`PgConfig::from_env()`; `PgStore` over `deadpool-postgres`, holding
no scope or session field.
- [ ] **1** `Cargo.toml`: add rmcp, tokio, tokio-postgres,
      deadpool-postgres, serde, serde_json, schemars, uuid, thiserror
- [ ] **2** `src/config.rs`: `PgConfig::from_env()` reads `PGHOST`,
      `PGDATABASE`, `PGOPTIONS`; user hardcoded to `agentmem_mcp`
- [ ] **3** `src/store.rs`: `trait MemoryStore` (5 async fns) and
      `PgStore` calling `agentmem.<fn>($1,...)` fresh per call
- [ ] **4** In `rust/dots-memory-mcp`, `cargo build`; add the crate to
      `flake/packages.nix` (`buildRustPackage`, imitate `hyprmon`);
      `nix build .#dots-memory-mcp` Expected: both builds succeed
- [ ] **5** `git commit -m "feat: scaffold the stateless memory mcp crate"`

### Task 2: Wire the five tools and their schemas
**Files:** create `src/tools.rs`; modify `src/main.rs`.
**Produces:** `recall`, `remember`, `forget`, `graph`, `session_note`
tools on the stdio server, schemas matching the tool map above.
- [ ] **1** `src/tools.rs`: one `#[tool]` handler per tool; each
      description states purpose, every argument, the `unslop_token`
      gate, and that `graph` renders Mermaid, never raw table rows
- [ ] **2** `src/main.rs`: build `PgStore::from_env()`, serve over stdio
- [ ] **3** Pipe `initialize` then `tools/list` JSON-RPC lines into
      `target/debug/dots-memory-mcp` Expected: exactly the five tool
      names above, no others
- [ ] **4** `git commit -m "feat: expose the five memory tools over stdio mcp"`

### Task 3: Error boundary, retry, and the stateless proof
**Files:** create `src/pgerr.rs`, `tests/stateless_scope.rs`.
**Produces:** `classify_error() -> Retry | Fatal(McpError)`; the
retry loop `remember`/`forget` use; proof calls never cross scopes.
- [ ] **1** `src/pgerr.rs`: SQLSTATE 40001 maps to `Retry`; anything
      else wraps the driver message into `McpError`, never a panic
- [ ] **2** `remember` and `forget` retry up to 3x with jittered
      backoff only when `classify_error` returns `Retry`
- [ ] **3** `tests/stateless_scope.rs`: `tokio::join!` two concurrent
      calls, scope `"a"` and `"b"`, against a `FakeStore` keyed per
      call argument; assert each result holds only its own scope
- [ ] **4** In `rust/dots-memory-mcp`: `cargo test`, `cargo fmt --all`,
      `cargo clippy -- -W clippy::all -W clippy::perf -W
      clippy::pedantic` Expected: tests pass, no warnings
- [ ] **5** `git commit -m "test: prove concurrent scopes stay isolated"`
