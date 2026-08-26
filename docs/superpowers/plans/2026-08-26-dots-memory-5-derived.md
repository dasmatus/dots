# dots-memory 5: Derived Edges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Fill the graph's `origin = 'derived'` half from the checkout, so
structural edges get rebuilt rather than corrected.
**Architecture:** One extractor walks the repo and prints Mermaid. One SQL
function shreds that through `agentmem.mermaid_edges` and swaps a scope's
derived rows inside one transaction, stamped with the commit it read.
**Tech Stack:** Rust, PostgreSQL 18.4, pgrx, Nix flake app.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- Needs plan 1's `agentmem.mermaid_edges` and plan 2's `relation` table
  carrying `origin` and `src_sha`. Land both first.
- Derived rows carry no provenance and are never superseded. They are
  deleted and rewritten per scope per commit. Staleness is a rebuild.
- An extractor never calls a model. Anything needing judgement is
  `remembered` and belongs to the other write path.
- Ids match `[A-Za-z0-9_]+` and are never `end`, `graph`, `class`,
  `click`, `style`, `subgraph`, `flowchart`, `linkStyle`, `href`, `call`
  or `classDef`. Those abort the parse or render an empty diagram.

---

### Task 1: Swap a scope's derived edges atomically
**Files:** create `nix/modules/agentmem/migrations/0003_derived.sql`;
modify `nix/modules/agentmem.nix` (migration list).
**Produces:** `agentmem.rebuild_derived(p_scope text, p_mermaid text,
p_sha text) RETURNS int`, returning the row count it wrote.

- [ ] **1** Write `0003_derived.sql`: `DELETE FROM agentmem.relation`
      for the scope `WHERE origin = 'derived'`, then `INSERT ... SELECT`
      from `agentmem.mermaid_edges(p_mermaid)`, stamping `src_sha`
- [ ] **2** Add the file to the migration list in `nix/modules/agentmem.nix`
- [ ] **3** On a throwaway cluster, call it twice with the same Mermaid
      `Expected:` identical row count both times, no duplicates
- [ ] **4** Call it with an edge removed
      `Expected:` that row is gone, not marked superseded
- [ ] **5** Confirm `remembered` rows in the same scope are untouched
      `Expected:` their count is unchanged across both calls
- [ ] **6** `git commit -m "feat: swap derived edges in one transaction"`

### Task 2: Read the structure out of the checkout
**Files:** create `rust/dots-memory-derive/{Cargo.toml,src/main.rs}`,
`tests/derive_emit.rs`; modify `flake/packages.nix`, `flake/apps.nix`.
**Produces:** binary `dots-memory-derive`, printing a `flowchart TD` over
the modules list in `flake/nixos.nix`, the imports in
`nix/home/default.nix`, `dots.*` declaration-to-use pairs, and the app
names in `flake/apps.nix`.

- [ ] **1** Write `tests/derive_emit.rs`: assert the output names
      `searxng.nix` as imported by `flake/nixos.nix`, and that every id
      matches `[A-Za-z0-9_]+`
- [ ] **2** `cd rust/dots-memory-derive && cargo test`
      `Expected:` FAIL, binary absent
- [ ] **3** Write `src/main.rs`: read the four sources, slugify, print
      Mermaid. Take the repo root as argv[1], defaulting to `.`
- [ ] **4** `cargo test` `Expected:` PASS
- [ ] **5** `cargo fmt --all && cargo clippy --all-targets -- -D warnings`
      `Expected:` clean
- [ ] **6** Add the crate to `flake/packages.nix` and its lint line to
      `flake/apps.nix`, beside the other crates
- [ ] **7** `git commit -m "feat: read the repo structure into mermaid"`

### Task 3: Wire the rebuild to a command
**Files:** modify `flake/apps.nix` (new `memory-derive` app).
**Produces:** `nix run .#memory-derive`, piping the extractor into
`rebuild_derived` at `git rev-parse HEAD`.

- [ ] **1** Add `memory-derive` to `flake/apps.nix` using `mkShellApp`,
      with `runtimeInputs = [ pkgs.postgresql_18 ]`
- [ ] **2** `nix run .#memory-derive` `Expected:` prints a row count
- [ ] **3** `psql -Atc "select count(*) from agentmem.relation where
      origin='derived'"` `Expected:` matches that count
- [ ] **4** Run it twice `Expected:` the count is stable, not doubled
- [ ] **5** `nix run .#nix-lint` `Expected:` green
- [ ] **6** `git commit -m "feat: rebuild the derived graph on demand"`
