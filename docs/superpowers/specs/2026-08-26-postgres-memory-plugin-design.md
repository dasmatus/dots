# Postgres-backed memory plugin: design

**Goal:** Replace Claude Code's built-in memory, switched off at
`nix/home/ai/claude.nix:262`, with a first-party plugin whose store is a local
PostgreSQL instance, whose graph ingest path is a Rust extension, and whose
every write is a visible tool call.

**Status:** approved design, not yet built. Implementation plan follows
separately.

---

## 1. Why this exists, and why the obvious version fails

Auto-memory was disabled deliberately. The comment states the reason: nothing
about a session should leak into the next one behind the user's back. Any
replacement that harvests transcripts recreates exactly what was turned off.

Three audits set the bar this design has to clear.

| Source | Finding |
|---|---|
| mem0 production audit (github.com/mem0ai/mem0/issues/4573) | 10,134 entries, 224 worth keeping. 97.8% junk. 3,200 restated the system prompt. 808 entries asserted "User prefers Vim"; nobody used Vim. |
| Theo Browne, 2026-08-25 | 355 sessions: memory written 80 times, read 19. 26 of 45 files never read once. ~10 were point-in-time state he classed as actively risky. |
| Harvard D3, quoted in the mem0 issue | Indiscriminate storage performs worse than no memory. Filtering before storage gained ~10%. |

The mem0 loop is the instructive one. A hallucinated fact was recalled into
context, re-extracted as though it were fresh observation, and stored again.
Their own top-ranked fix is to tag recalled memories so the extractor skips
them.

Theo's objection is structural rather than incidental: code is the ground
truth, and a remembered graph diverges from it silently. For this repo, `rg`,
`git log` and `nix eval` already answer "what imports `form-factor.nix`"
correctly and by construction. That objection is accepted, and section 6
answers it.

## 2. What was verified before designing

Every claim below was run on this machine, not recalled.

| Question | Answer |
|---|---|
| PostgreSQL in the pin | 18.4, prebuilt on cache.nixos.org. Nothing installed; zero references in `nix/`. |
| pgrx | `cargo-pgrx` 0.18.1, `pkgs.buildPgrxExtension` at `all-packages.nix:4097`. `pg_search`, `pg_graphql`, `pgx_ulid` all `broken = false` on `postgresql18Packages`; `pg_graphql` resolves to a real derivation. pg18 needs no fallback to 17. |
| Keyword recall | Built-in FTS works with no extension. `pg_trgm` 1.6, `unaccent` 1.1, `btree_gin` 1.3 ship in the base package. |
| Slovak text search | No configuration exists. 30 stemmers, none Slovak or Czech. Fall back to `simple` plus `unaccent` plus trigrams. |
| Embeddings | Unavailable. `aiOllama = false` in `nix/data/settings.nix:10`, no binary, `/var/lib/ollama` empty, nothing on 11434, no model pulled. |
| Hooks that reach the model | Plain stdout on three events only: `SessionStart`, `UserPromptSubmit`, `UserPromptExpansion`. `hookSpecificOutput.additionalContext` on eleven, including `Stop`. `SessionEnd`, `PreCompact` and `PostCompact` have no variant and fail schema validation. |
| Mermaid token cost | Same 15-entity, 25-relation graph: outline 410, table 594, Mermaid 597, minified JSON 854, pretty JSON 1206. Structure-only Mermaid, no observations: 367. |
| Mermaid parsers | None. `mermaid.parse()` returns `{diagramType}` and nothing else. `@mermaid-js/parser` v1.2.0 has no flowchart grammar. |
| The read path, end to end | Confirmed with a throwaway plugin. `hooks/hooks.json` carrying the outer `{"hooks": {...}}` wrapper loaded both events; `plugin details` reported `Hooks (2) SessionStart, Stop` and `MCP servers (1)`. `${CLAUDE_PLUGIN_ROOT}/bin/<name>` resolved and executed, and a fresh headless session read the hook's stdout marker back out of its own context. |

## 3. Layout

| Path | Purpose |
|---|---|
| `rust/pg-agentmem/` | pgrx extension: Mermaid parser, `norm_hash_v1`, slugifier, renderer. |
| `rust/dots-memory-mcp/` | Stateless stdio MCP server over `tokio-postgres`. |
| `plugins/dots-memory/` | `.claude-plugin/plugin.json`, `.mcp.json`, `hooks/hooks.json`, `skills/memory/SKILL.md`. |
| `nix/modules/services/agentmem.nix` | Pinned `postgresql_18`, extension, peer auth, backups. |
| `nix/modules/system/impermanence.nix` | One added entry, `/var/lib/postgresql`. |
| `nix/home/ai/claude.nix` | Plugin derivation plus `plugins.dots-memory`. |
| `flake/nixos.nix` | The new module added to the literal `modules` list. |
| `tests/` | Parser tests and a VM test. Never inline. |

The plugin ships its own `.claude-plugin/plugin.json`, which suppresses the
Home Manager module's synthesized manifest. `.mcp.json` and `hooks/hooks.json`
reference `${CLAUDE_PLUGIN_ROOT}/bin/<name>`; a `runCommand` supplies `bin/`
as store symlinks. That keeps both files checked in and diffable instead of
forcing the whole tree through `builtins.toJSON` on every rebuild.

## 4. The privilege boundary is the anti-junk mechanism

```sql
GRANT USAGE   ON SCHEMA   agentmem TO agentmem_mcp;
GRANT EXECUTE ON FUNCTION agentmem.ingest_fact, agentmem.cite_fact,
                          agentmem.digest, agentmem.search,
                          agentmem.subgraph,   agentmem.note_session,
                          agentmem.health TO agentmem_mcp;
-- no GRANT ... ON TABLE anywhere
```

Two functions are deliberately withheld from that role.
`agentmem.rebuild_derived` swaps a scope's derived edges wholesale and
`agentmem._mark_stale` retires facts whose source is gone; both are
maintenance the service runs, not calls an agent gets to make. A test
asserts `_mark_stale` is denied to `agentmem_mcp`.

The MCP role holds no table privileges. `agentmem.ingest_fact` is the only way
a row can come into being, and it carries four gates:

1. **unslop** rejects prose that has not been through the cleaning pass.
2. **recall echo** rejects text the digest served this session.
3. **digest echo** rejects text already live in the store.
4. **content address** rejects a duplicate by hash, across live and superseded
   rows alike.

The callable surface, fixed as the interface contract; every plan and
every caller matches these names and types verbatim:

```sql
ingest_fact(p_scope text, p_claim_key text, p_body text,
            p_source_kind text, p_source_ref text,
            p_unslop_token text, p_session uuid) RETURNS bigint
cite_fact(p_fact bigint, p_session uuid) RETURNS void
digest(p_scope text, p_max_rows int, p_max_chars int) RETURNS text
search(p_scope text, p_q text, p_k int)
  RETURNS TABLE(fact_id bigint, claim_key text, body text, rank real)
subgraph(p_scope text, p_root text, p_hops int)
  RETURNS TABLE(src text, verb text, dst text, depth int, origin text)
note_session(p_session uuid, p_scope text, p_summary text,
             p_files text[], p_decisions text, p_unfinished text,
             p_unslop_token text) RETURNS void
health(p_since interval DEFAULT '30 days')
  RETURNS TABLE(reads bigint, writes bigint, ratio numeric,
                oldest_fact_age interval, live_facts bigint,
                superseded_facts bigint, stale_facts bigint,
                verdict text)
```

Maintenance, run by the service rather than by an agent:

```sql
rebuild_derived(p_scope text, p_mermaid text, p_sha text) RETURNS int
_mark_stale() RETURNS void
```

The mem0 duplication loop needs a direct `INSERT`. There is none. This is also
what makes the server stateless in a way that cannot rot: it holds no state
because it is not permitted to hold any.

### Content addressing needs the extension

Plain SQL cannot do gate 4. The text-to-bytea cast runs through `byteain`,
which interprets backslash-hex escapes, so distinct texts collide:

```sql
SELECT '\x414243'::bytea = 'ABC'::bytea;                             -- t
SELECT sha256('\x616263'::text::bytea) = sha256('abc'::text::bytea); -- t
```

The safe spelling is refused outright, because `convert_to` is
`provolatile = 's'`:

```sql
CREATE TABLE t (s text,
  h bytea GENERATED ALWAYS AS (sha256(convert_to(s,'UTF8'))) STORED);
-- ERROR: generation expression is not immutable
```

So `agentmem.norm_hash_v1(text) -> bytea`, an `IMMUTABLE` pgrx function that
normalises then hashes, is load-bearing rather than convenient. The extension
parses Mermaid, and it is also the only place a correct content address can
exist. The second reason would justify it on its own.

### PostgreSQL 18 generated columns

PG18 defaults `GENERATED ALWAYS AS` to `VIRTUAL`, and virtual columns cannot
be indexed:

```sql
CREATE TABLE t (a int, b int GENERATED ALWAYS AS (a*2));  -- attgenerated 'v'
CREATE INDEX ON t (b);
-- ERROR: indexes on virtual generated columns are not supported
```

Every generated column in this schema spells out `STORED`. Omitting it makes
the tsvector and hash indexes uncreatable, with no error until the index is
attempted.

## 5. Supersession

Nine tables: `scope`, `session`, `entity`, `relation`, `fact`, `diagram`,
`provenance`, `claim_provenance`, `recall`. The distilled session summary is a
column on `session`, so its primary key gives one summary per session with no
extra constraint.

Corrections retire their predecessor rather than sitting beside it:

```sql
CREATE UNIQUE INDEX fact_live_claim_uk
  ON agentmem.fact (scope_id, claim_key) WHERE superseded_at IS NULL;
```

A concurrent second writer for the same claim fails at the index instead of
forking history, and `ingest_fact` raises `40001 SUPERSEDE_LOST` when its
close-then-insert matches zero rows, so the client retries. Recall returns
superseded rows marked rather than hiding them, so a retraction and the
correction that replaced it are both reachable.

Bitemporal ranges were rejected on evidence. PG18 ships
`PRIMARY KEY (key, valid WITHOUT OVERLAPS)`, which enforces non-overlap, but
`UPDATE ... FOR PORTION OF` is still a syntax error. Every supersession would
need hand-written range splitting in application code.

## 6. Read, nudge, write

```
SessionStart -> agentmem.digest(scope) -> indented outline -> additionalContext
                capped at ~40 rows and ~1500 tokens
                pinned, live, non-stale only
                every row tagged [recalled memory - do not re-store]

Stop         -> additionalContext -> "nothing durable was recorded this
                                      session; if something was learned,
                                      call remember"

model        -> remember(...) -> a visible tool call, refusable
```

The digest is the outline, not Mermaid. Mermaid costs 46% more for identical
triples and the rendered picture never reaches the model during a session.
Mermaid is a `graph(node, hops)` tool, invoked when a human wants to look,
over a one-hop or two-hop neighbourhood. It is never the store, never the
injection format, and never rendered whole; past roughly forty nodes the
layout is a hairball, which destroys its only advantage.

Nothing is harvested. The `Stop` hook asks a question; it does not read the
transcript and decide. That preserves the property `claude.nix:262` was
protecting.

## 7. Edges, split by origin

| `origin` | Source | Lifecycle |
|---|---|---|
| `derived` | Mechanical extractors over the checkout: the `modules` list in `flake/nixos.nix`, the `imports` in `nix/home/default.nix`, `dots.*` declaration-to-consumption pairs, `flake/apps.nix` names, crate dependencies | Truncate and rebuild at a commit. Staleness is a rebuild, never a correction. Every edge records the SHA it came from. |
| `remembered` | Agent-emitted Mermaid, for what the code cannot state: why a thing exists, what was rejected and why | Provenance, supersession, staleness sweep. |

Both reach the database through `mermaid_edges()`. One parser, two policies.
This is the answer to Theo's objection: structural facts are derived and
regenerable, and the agent may only assert what no extractor could compute.

## 8. The parser rejects rather than guesses

Mermaid's failure modes are silent, verified against `mmdc` 11.16.0:

| Input | Result |
|---|---|
| `dev---ops` | Renders a node named `ps`. The `o` is consumed as a circle-edge terminator. Exit 0. |
| `click` as a node id | Valid, empty SVG. Zero nodes. Exit 0. Still live as mermaid-js/mermaid#4182. |
| `A["He said "hi""]` | Nested quotes silently dropped. `#quot;` is the only correct escape. |
| `A -- text ==> B` | Edge type `INVALID` pushed into the edge list. No throw. |
| `call, class, classDef, end, flowchart, graph, href, linkStyle, style, subgraph` as ids | Hard parse error. |

Because no Mermaid parser exists in any language's official tooling, the Rust
one is written against the authoritative jison grammar and accepts a defined
subset. Outside that subset it errors. It normalises every link length to one
verb, treats `arrow_open` and `~~~` as undirected rather than coercing a
direction, and refuses mid-form edges whose opener and closer strokes
disagree. On emit it slugifies ids to `[A-Za-z0-9_]+`, blocklists the reserved
words above plus `click`, spaces both sides of every arrow, and brackets and
quotes every label with entity escaping.

Exit code 0 is never treated as validation.

The extension's SQL surface, equally fixed, all `IMMUTABLE`, all in
schema `agentmem`:

```sql
norm_hash_v1(input text) RETURNS bytea
slug_v1(input text) RETURNS text
mermaid_edges(doc text)
  RETURNS TABLE(ord int, src text, verb text, dst text, directed bool)
edges_to_mermaid(src text[], verb text[], dst text[]) RETURNS text
```

## 9. Operational constraints

| Constraint | Consequence |
|---|---|
| `/` is tmpfs, wiped each boot (`nix/modules/system/impermanence.nix:24-31`) | `/var/lib/postgresql` must be persisted, the parent and not the versioned subdirectory. Without it, `preStart` re-initdbs a blank cluster every boot with no error. |
| No `system.stateVersion` anywhere; `maintenance.nix:40-53` autoupgrades daily | `services.postgresql.package` is pinned explicitly. Unpinned, a channel gaining `postgresql_19` moves `psqlSchema` and `dataDir` under a live cluster. |
| `nix.gc` weekly with `--delete-older-than 0d` (`maintenance.nix:26-30`) | No rollback net. `services.postgresqlBackup` ships in v1, relocated off its `/var/backup/postgresql` default, which is also on the tmpfs. |
| `nix/system/hosts.nix:55-72` | Never `DynamicUser`. It relocates StateDirectory to `/var/lib/private`; the rename over an impermanence bind mount fails `EBUSY` and aborts `nixos-rebuild` at status 4. ollama paid for this already. |
| `nix/system/hosts.nix:74-90` | Never `ReadWritePaths` for a directory needing creation. It is a namespace directive; systemd neither creates nor chowns, and it fails `226/NAMESPACE` on a tmpfs root. |
| No secrets manager in the repo | Peer auth over the unix socket. `ensureDBOwnership` forces the database name to equal the role name, so the database is `matus` and `claude_memory` becomes the schema. `initialScript` is `types.path` and lands world-readable in the store. |
| firewalld with `DefaultZone = "drop"` | `enableTCPIP` stays false. `true` sets `listen_addresses = "*"`, every interface, not localhost. |
| `~/.claude/settings.json` is a 0444 store symlink | Hook registration is declarative only. The plugin's bundled `hooks/` merges with the existing settings hook; neither overrides the other. |

Two `SessionStart` handlers will fire: the existing one at
`claude.nix:202-211`, which injects all of `dodging-cdb`, and this plugin's.
There is no dedup across the two, so the combined injection is budgeted as one
number.

## 10. Instrumentation and the kill criterion

A `recall` ledger counts reads against writes from the first row. The
benchmark is Theo's audit: 80 writes against 19 reads, and 26 of 45 files
never opened.

**If reads do not exceed writes within one month of the first stored row, this
store is net-negative and gets deleted rather than tuned.** That is a
commitment in the design, not an aspiration, and the ledger exists to make it
checkable rather than arguable.

## 11. Out of scope for v1

- **Embeddings.** Enabling them costs a `settings.nix` edit, a rebuild, CPU
  inference on a gfx90c that ROCm does not target, a cold-start stall on every
  recall, a permanent dimension commitment, and a fix for the latent bug at
  `nix/system/hosts.nix:71,85` that materialises a broken unitless `ollama.service`
  even while the toggle is off. `tsvector` plus `pg_trgm` is verified working
  and needs none of it.
- **Raw transcripts.** The JSONL already exists under `~/.claude/projects/`
  and every hook receives `transcript_path`. One distilled summary row per
  session is stored; the conversation is not copied.
- **Cross-machine sync.**
- **Externally fetched content on the write path.** Sleeper poisoning
  (arXiv 2605.15338) reached injection rates between 64% and 99% across the
  assistants tested, and retrieved poisoned rows drove attacker-intended
  actions 60 to 89% of the time. Prompt-level defences were measured as
  failing once the attack adapts, so the boundary here is structural: fetched
  content never reaches `ingest_fact`.

## 12. Open risks, unmitigated

Named as risks rather than solved, per the repo's planning rules.

1. **Hook behaviour is pinned to `claude-code` 2.1.228.** The event list and
   the `additionalContext` mapping were read out of the bundled JS; the
   published docs list roughly ten more capable events than the binary
   implements. The read path itself was then confirmed against a live session
   rather than left inferred, so what remains at risk is the wider event
   table, not the mechanism. Re-verify after a CLI bump; this machine
   autoupgrades daily.
2. **No latency measurement at target scale.** The live test cluster held three
   rows and planned a sequential scan. Nobody has measured tsvector plus
   trigram over a few thousand realistic rows on this CPU.
3. **No `pg_upgrade` rehearsal.** The major-version path is understood and has
   not been executed here, and there is no `services.postgresql.upgrade`
   option.
4. **Concurrency under parallel subagents is uninvestigated.** The
   `zellij-subagents` workflow can put several sessions on the same database.
   The partial unique index makes a lost supersession loud rather than silent,
   which is a floor, not a story.
5. **Token counts are a tiktoken proxy.** Ratios held within 2.5% across two
   encodings, so the ratios are sound and the absolute numbers are indicative.
6. **The prior-art numbers carrying the most design weight are secondary
   sources.** Theo's audit figures come from a summary rather than his post,
   and the Harvard D3 figure is quoted inside the mem0 issue rather than read
   at source. The design does not rest on any single one of them.
