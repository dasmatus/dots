-- agentmem schema, migration 1 of 2.
--
-- Nine tables, a privilege boundary, and the supersession index. No
-- function in this file may be called by agentmem_mcp: that role gets
-- USAGE on the schema only here, and EXECUTE on five functions in
-- 0002_functions.sql. There is deliberately no GRANT ... ON TABLE
-- anywhere in either file — agentmem.ingest_fact is the only path a
-- row can take into this schema.
--
-- pg_agentmem supplies norm_hash_v1 and slug_v1 as IMMUTABLE pgrx
-- functions (rust/pg-agentmem, plan 1). Both are load-bearing for the
-- generated columns below, not merely convenient: a text->bytea cast
-- misparses backslash-hex escapes, and the correct spelling
-- (convert_to) is only STABLE, so it cannot appear in a generated
-- column at all. See the design spec section 4 for the byte-for-byte
-- collision this avoids.
--
-- No manual CREATE SCHEMA here: pg_agentmem's own extension script
-- (pgrx's #[pg_schema] macro) issues its own CREATE SCHEMA IF NOT
-- EXISTS agentmem, and CREATE EXTENSION ... SCHEMA agentmem demands
-- the schema already exist. Pre-creating it manually collides with
-- that self-creation — "schema agentmem is not a member of
-- extension pg_agentmem", since IF NOT EXISTS inside an extension
-- script may only skip an object the extension already owns. Letting
-- pg_agentmem create and own the schema first sidesteps that; pg_trgm
-- and unaccent then install into it by name, which needs it to exist
-- but not to be owned by either of them.
--
-- All three installed into agentmem itself rather than the default
-- public schema: every API function below pins search_path to
-- (agentmem, pg_temp), so similarity(), the trigram operators and the
-- unaccent dictionary all need to resolve from inside this schema.
CREATE EXTENSION IF NOT EXISTS pg_agentmem;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA agentmem;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA agentmem;

-- unaccent() ships marked STABLE, because its dictionary can be
-- altered at runtime — but the default dictionary never is here, so
-- this wrapper is the standard way to use it inside a generated
-- column or a functional index. Every generated column below spells
-- STORED explicitly: PG18 defaults GENERATED ALWAYS AS to VIRTUAL,
-- and a virtual column cannot be indexed at all, with no error until
-- CREATE INDEX is attempted.
CREATE FUNCTION agentmem.f_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
  $$ SELECT agentmem.unaccent('agentmem.unaccent'::regdictionary, $1) $$;

-- One row per distinguishable memory namespace (a repo, a project). Every
-- other table hangs off scope_id so scopes never mix in search or digest.
CREATE TABLE agentmem.scope (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- One row per Claude Code session. The distilled summary is a plain
-- column here rather than its own table, which is what gives one
-- summary per session for free from the primary key, with no
-- additional uniqueness constraint to maintain.
CREATE TABLE agentmem.session (
  id         uuid PRIMARY KEY,
  scope_id   bigint NOT NULL REFERENCES agentmem.scope (id),
  summary    text,
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at   timestamptz
);

-- Named nodes a `remembered` relation or a digest can point at. slug is
-- the normalised, indexable identity; name is the display form.
CREATE TABLE agentmem.entity (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope_id   bigint NOT NULL REFERENCES agentmem.scope (id),
  name       text NOT NULL,
  slug       text GENERATED ALWAYS AS (agentmem.slug_v1(name)) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (scope_id, slug)
);

-- Edges, split by origin per the design spec section 7. `derived` edges
-- are mechanically extracted from the checkout and carry the commit SHA
-- they came from: staleness for them is a rebuild, never a correction.
-- `remembered` edges are agent-emitted Mermaid for what the code cannot
-- state, and go through provenance, supersession and the staleness
-- sweep like a fact does.
CREATE TABLE agentmem.relation (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope_id      bigint NOT NULL REFERENCES agentmem.scope (id),
  src           text NOT NULL,
  verb          text NOT NULL,
  dst           text NOT NULL,
  origin        text NOT NULL CHECK (origin IN ('derived', 'remembered')),
  src_sha       text,
  session_id    uuid REFERENCES agentmem.session (id),
  is_stale      boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  superseded_at timestamptz,
  CHECK (origin <> 'derived' OR src_sha IS NOT NULL)
);

CREATE INDEX relation_scope_src_idx ON agentmem.relation (scope_id, src);
CREATE INDEX relation_scope_dst_idx ON agentmem.relation (scope_id, dst);

-- The claim ledger. claim_key identifies "the answer to this question";
-- body is the claim itself. content_hash and body_tsv are both STORED
-- generated columns, per the constraints above.
CREATE TABLE agentmem.fact (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope_id      bigint NOT NULL REFERENCES agentmem.scope (id),
  claim_key     text NOT NULL,
  body          text NOT NULL,
  source_kind   text NOT NULL,
  source_ref    text NOT NULL,
  content_hash  bytea GENERATED ALWAYS AS (agentmem.norm_hash_v1(body)) STORED,
  body_tsv      tsvector GENERATED ALWAYS AS
                  (to_tsvector('simple', agentmem.f_unaccent(body))) STORED,
  session_id    uuid REFERENCES agentmem.session (id),
  pinned        boolean NOT NULL DEFAULT false,
  is_stale      boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  superseded_at timestamptz,
  -- The row this one replaced, and the row that replaced this one.
  -- Populated by ingest_fact so a retraction and the correction that
  -- replaced it are both reachable, per design spec section 5.
  supersedes    bigint REFERENCES agentmem.fact (id),
  superseded_by bigint REFERENCES agentmem.fact (id)
);

-- Corrections retire their predecessor instead of sitting beside it. A
-- concurrent second writer for the same claim fails here rather than
-- forking history; ingest_fact turns that into 40001 SUPERSEDE_LOST.
CREATE UNIQUE INDEX fact_live_claim_uk
  ON agentmem.fact (scope_id, claim_key) WHERE superseded_at IS NULL;

CREATE INDEX fact_body_tsv_gin ON agentmem.fact USING gin (body_tsv);
CREATE INDEX fact_body_trgm_gin ON agentmem.fact USING gin (body agentmem.gin_trgm_ops);
CREATE INDEX fact_content_hash_idx ON agentmem.fact (scope_id, content_hash);

-- Raw Mermaid a human asked to see, not the store and not the
-- injection format (design spec section 6). Kept for audit only.
CREATE TABLE agentmem.diagram (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope_id   bigint NOT NULL REFERENCES agentmem.scope (id),
  session_id uuid REFERENCES agentmem.session (id),
  title      text,
  doc        text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Deduplicated sources a fact can cite: a file path, a commit, a URL.
CREATE TABLE agentmem.provenance (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind       text NOT NULL,
  ref        text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, ref)
);

-- Join table: every provenance a claim_key was ever backed by, across
-- its supersession history, so the audit trail survives a correction.
CREATE TABLE agentmem.claim_provenance (
  fact_id       bigint NOT NULL REFERENCES agentmem.fact (id),
  provenance_id bigint NOT NULL REFERENCES agentmem.provenance (id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fact_id, provenance_id)
);

-- The read ledger (design spec section 10). Every digest row and every
-- cite_fact call logs one entry here; search() takes no session
-- argument in its fixed signature, so it has nothing to attribute a
-- read to and logs nothing. ingest_fact's recall-echo gate reads this
-- table back; the kill criterion is reads outnumbering writes
-- (agentmem.fact inserts) within a month of the first row. session_id
-- is nullable because digest's fixed signature carries no p_session
-- either — a SessionStart read is logged against the scope only.
CREATE TABLE agentmem.recall (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope_id   bigint NOT NULL REFERENCES agentmem.scope (id),
  session_id uuid REFERENCES agentmem.session (id),
  fact_id    bigint NOT NULL REFERENCES agentmem.fact (id),
  action     text NOT NULL CHECK (action IN ('digest', 'cite')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX recall_session_idx ON agentmem.recall (session_id);
CREATE INDEX recall_fact_idx ON agentmem.recall (fact_id);

-- The privilege boundary itself. agentmem_mcp is created by the ident
-- map in agentmem.nix (peer auth, OS user matus mapped to both matus
-- and agentmem_mcp); it is granted schema USAGE here and nothing on
-- any table. 0002_functions.sql grants EXECUTE on the five callable
-- functions and nothing else.
GRANT USAGE ON SCHEMA agentmem TO agentmem_mcp;
