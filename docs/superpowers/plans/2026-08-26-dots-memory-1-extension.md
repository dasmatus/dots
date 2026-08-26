# Postgres Memory Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Ship a buildable `pg_agentmem` pgrx extension exporting
`norm_hash_v1`, `slug_v1`, `mermaid_edges`, `edges_to_mermaid`.
**Architecture:** One pgrx crate, `schema agentmem`, every function
`IMMUTABLE`. No tables, roles, or service config; plan 2 builds on top.
**Tech Stack:** Rust, pgrx 0.18.1, sha2, unicode-normalization,
PostgreSQL 18.4, Nix.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- `rust/pg-agentmem`, `pg_agentmem`, edition 2021, `AGPL-3.0-only`;
  `pgrx = "=0.18.1"` = `pkgs.cargo-pgrx` (unversioned attr);
  `postgresql = pkgs.postgresql_18`.
- All four functions `#[pg_extern(immutable, schema="agentmem")]`.
- Formatting gate: `cargo fmt --all && cargo clippy --all-targets --
  -W clippy::all -W clippy::perf -W clippy::pedantic`, run in
  `rust/pg-agentmem`.
- pgrx's empty `pg_test` stub stays in `src/lib.rs`; real assertions
  live in `rust/pg-agentmem/tests/*.rs` via `Spi::get_one` (open risk:
  no cleaner seam). `doCheck = true`, so `nix build .#pg-agentmem`
  proves every test (open risk: no devShell wiring for `cargo pgrx test`).
---
### Task 1: Scaffold the crate, wire Nix, add norm_hash_v1
**Files:** `rust/pg-agentmem/{Cargo.toml,src/lib.rs,src/hash.rs,
tests/hash.rs}`; modify `flake/packages.nix`, `flake/apps.nix`.
**Produces:** crate `pg_agentmem`, `packages.pg-agentmem`,
`agentmem.norm_hash_v1(input text) -> bytea`.
- [ ] **1** Write `Cargo.toml`/`src/lib.rs`: crate-type
      `["cdylib","rlib"]`, `pgrx = "=0.18.1"`, features
      `default=["pg18"]`, `pg18=["pgrx/pg18"]`,
      `pg_test=["pgrx/pg_test"]`, deps `sha2`, `unicode-normalization`;
      `pg_module_magic!()`, `mod hash;`, empty `pg_test` harness stub
- [ ] **2** Write `src/hash.rs`: NFC-normalise the `&str` arg, SHA-256
      its UTF-8 bytes, return `Vec<u8>` -- never a `::bytea` cast
- [ ] **3** Add `pg-agentmem` to `flake/packages.nix`
      (`buildPgrxExtension`, `postgresql = pkgs.postgresql_18`,
      `cargo-pgrx = pkgs.cargo-pgrx`, `doCheck = true`) and
      `nix build .#pg-agentmem` to `nix-lint` in `flake/apps.nix`
- [ ] **4** Write `tests/hash.rs`: `#[pg_test]` via `Spi::get_one`,
      asserting `norm_hash_v1('\x616263')` differs from
      `norm_hash_v1('abc')`
- [ ] **5** Run the formatting gate; `nix build .#pg-agentmem`
      Expected: builds, hash tests pass
- [ ] **6** `git commit -m "feat: scaffold pg_agentmem and add norm_hash_v1"`
### Task 2: mermaid_edges parser, slug_v1, edges_to_mermaid
**Files:** `rust/pg-agentmem/{src/mermaid.rs,src/render.rs,
tests/mermaid_edges.rs,tests/edges_to_mermaid.rs}`; modify `src/lib.rs`.
**Produces:** `mermaid_edges(doc text) -> TABLE(ord int, src text,
verb text, dst text, directed bool)`, `slug_v1(input text) -> text`,
`edges_to_mermaid(src text[], verb text[], dst text[]) -> text`.
- [ ] **1** `mermaid.rs`: parse solid `--> --- --o --x`, thick
      `==> === ==o ==x`, dotted `-.-> -.-`, invisible `~~~`; both
      `A -->|t| B` and `A -- t --> B`; one verb per link length;
      `arrow_open`/`~~~` set `directed = false`
- [ ] **2** In `mermaid.rs`, fold `A --> B --> C` into one row per hop
      (left fold); expand `A & B --> C & D`; skip `subgraph`/`end`,
      `direction`, `class`/`classDef`/`style`/`click`/`linkStyle`,
      `%%` comments, the header line; reject anything else outright
- [ ] **3** In `mermaid.rs`, reject the reserved ids `call class
      classDef end flowchart graph href linkStyle style subgraph
      click`; wire `mermaid_edges` returning `TableIterator`
- [ ] **4** `tests/mermaid_edges.rs`: `dev---ops` must not yield a
      node named `ps`; one case per edge family; both label forms;
      chaining; `&` expansion; reserved words rejected; stroke
      mismatch `A -- t ==> B` rejected; one out-of-subset rejected
- [ ] **5** `render.rs`: `slug_v1` maps input to `[A-Za-z0-9_]+`;
      `edges_to_mermaid` slugifies both endpoints, blocklists the
      reserved words above plus `click`, spaces every arrow, brackets
      and quotes labels, escapes `"`/`#`/`|` as `#quot;`/`#35;`/`#124;`
- [ ] **6** `tests/edges_to_mermaid.rs`: a label with a literal double
      quote survives the round trip; no reserved word appears as a
      rendered slug
- [ ] **7** Run the formatting gate; `nix build .#pg-agentmem`
      Expected: all four functions' tests pass
- [ ] **8** `git commit -m "feat: parse and render the flowchart subset"`
