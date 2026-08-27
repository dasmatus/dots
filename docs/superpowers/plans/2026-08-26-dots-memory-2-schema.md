# Dots Memory 2: Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Give `agentmem` its nine tables, privilege boundary, and
five API functions, applied idempotently and proven by test.
**Architecture:** Numbered SQL migrations under a `postStart` runner build
the tables; a second migration adds the only functions allowed to touch them.
**Tech Stack:** PostgreSQL 18.4, pgrx (plan 1), plain SQL, psql.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- Run after plan 0 (cluster) and plan 1 (`packages.pg-agentmem`).
- `matus`/`agentmem`/`agentmem_mcp`: db, schema, mcp role, on socket
  `/run/postgresql`; the mcp role holds zero table privileges.
- Function signatures are fixed in spec section 4; match them verbatim.
- Peer auth maps OS users to same-named roles, so `agentmem.nix` needs
  `services.postgresql.identMap` sending OS user `matus` to both roles
  and an `authentication` line `local matus agentmem_mcp peer map=...`.
- Generated columns spell `STORED`; PG18's `VIRTUAL` default is
  unindexable and fails silently until `CREATE INDEX`.
- `fact_live_claim_uk` on `(scope_id, claim_key) WHERE superseded_at IS
  NULL`; no bitemporal ranges, PG18 has no `FOR PORTION OF`.
- Rank via `simple`+`unaccent`+`pg_trgm`, no Slovak config. Open risk:
  concurrent `ingest_fact` races surface as `40001` (spec open risk 4).
- `recall` is the spec-10 read ledger; reads must beat writes in a month.

---
### Task 1: Migrations, tables, privilege boundary, supersession
**Files:** create `nix/modules/agentmem/migrations/0001_schema.sql`
and `tests/agentmem/{generated_columns,privilege_boundary,
supersession_race}.sql`; modify `nix/modules/agentmem.nix`.
**Produces:** role `agentmem_mcp`; the nine spec section 5 tables
(`session.summary` a plain column); `entity.slug`, `fact.content_hash`,
`fact.body_tsv` all `STORED`; `fact_live_claim_uk`; `relation.origin`
('derived'|'remembered') plus `relation.src_sha` (spec section 7).
- [ ] **1** In `agentmem.nix`, add `services.postgresql.extensions =
      [ pg-agentmem ]`, the ident map above, and a `postStart` runner
      tracked by `agentmem._migrations`; write `0001_schema.sql`:
      `CREATE SCHEMA agentmem`, `CREATE EXTENSION pg_agentmem`, the
      nine tables with supersession columns,
      `entity.slug`/`fact.content_hash` via `slug_v1`/`norm_hash_v1`,
      `fact.body_tsv` as `to_tsvector('simple', unaccent(body))`, all
      `STORED`, GIN/`pg_trgm` indexes, `fact_live_claim_uk`, `USAGE`
- [ ] **2** `sudo nixos-rebuild test --flake .`; check `attgenerated`
      in `pg_attribute` for `agentmem.fact` and `agentmem.entity`;
      `psql -U agentmem_mcp -d matus -c "insert into agentmem.fact
      default values"` Expected: generated columns all `s`; the
      insert denied by privilege, not by authentication
- [ ] **3** Write `generated_columns.sql`/`privilege_boundary.sql`
      capturing step 2; `supersession_race.sql`: two `fact` rows
      sharing `(scope_id, claim_key)`, both `superseded_at IS NULL`;
      `psql -d matus -f tests/agentmem/supersession_race.sql`
      Expected: second insert errors on `fact_live_claim_uk`
- [ ] **4** `git commit -m "feat: add agentmem schema and privilege boundary"`

### Task 2: The five API functions
**Files:** create `nix/modules/agentmem/migrations/0002_functions.sql`,
`tests/agentmem/ingest_gates.sql`.
**Produces:** `ingest_fact`, `cite_fact`, `digest`, `search`,
`subgraph` per spec section 4's signatures, `EXECUTE` granted only to
`agentmem_mcp`; `agentmem._mark_stale()`, owner-only, no grant.
- [ ] **1** Write `0002_functions.sql` per spec sections 4-6: `ingest_fact`
      gates unslop token, recall echo (via `recall`), digest echo (any
      live `fact.body`), content address (`norm_hash_v1`); on success
      it closes the prior live `p_claim_key` row and inserts, raising
      `40001 SUPERSEDE_LOST` on zero rows closed; `cite_fact`; `search`
      (`ts_rank_cd` + `pg_trgm` `similarity()`); `subgraph` (CTE over
      `relation`, `p_hops`-bounded); `digest` (indented outline, live
      non-stale pinned-first rows, capped `p_max_rows`/`p_max_chars`,
      rows prefixed `[recalled memory - do not re-store]`, logged to
      `recall`); `_mark_stale()`; `EXECUTE` on the five to the mcp role
- [ ] **2** `sudo nixos-rebuild test --flake .`; write `ingest_gates.sql`
      with one rejection per gate, then a fifth call passing all four.
      Expected: five functions listed in `\df agentmem.*`
- [ ] **3** `psql -d matus -f tests/agentmem/ingest_gates.sql`
      Expected: four distinct rejections, one new live row
- [ ] **4** `git commit -m "feat: add the five agentmem api functions"`
