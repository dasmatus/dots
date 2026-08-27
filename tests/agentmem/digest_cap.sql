-- Exercises agentmem.digest's two caps -- p_max_rows and p_max_chars --
-- together with the exclusions and the tag it promises (design spec
-- section 6; migration 0002_functions.sql):
--   * pinned rows sort first, most-recent-first within each group
--   * a superseded row and a stale row are both absent regardless of
--     either cap
--   * p_max_rows and p_max_chars are each independently load-bearing,
--     not just "whichever is smaller happens to bind"
--   * every emitted line carries the literal
--     "[recalled memory - do not re-store]" tag -- the mechanism a
--     re-extraction pass checks for before deciding whether a body is
--     fresh or already-served (design spec section 1, the mem0
--     duplication loop this schema exists to close)
--
--   psql -d matus -f tests/agentmem/digest_cap.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope      text := 'digest-cap-test';
  v_session    uuid := gen_random_uuid();
  v_tag        text := '[recalled memory - do not re-store]';
  v_out        text;
  v_line_count int;
  v_tag_count  int;
  v_len_p2     int;
  v_len_p1     int;
BEGIN
  -- Eight ingest_fact calls, then created_at is stamped explicitly for
  -- every one of them below: clock_timestamp() advances too coarsely
  -- to trust for ordering here (this test's own run showed two
  -- back-to-back statements landing on the same microsecond, at which
  -- point "pinned DESC, created_at DESC" ties and falls back to
  -- whatever order the planner happens to scan rows in). Pinning
  -- created_at directly makes the intended order load-bearing instead
  -- of a hardware-speed accident.
  PERFORM agentmem.ingest_fact(v_scope, 'k-super', 'old body value', 'test', 'ref',
    agentmem.unslop_token('old body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'c1', 'c1 body value', 'test', 'ref',
    agentmem.unslop_token('c1 body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'p1', 'p1 body value', 'test', 'ref',
    agentmem.unslop_token('p1 body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'c2', 'c2 body value', 'test', 'ref',
    agentmem.unslop_token('c2 body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'stale1', 'stale body value', 'test', 'ref',
    agentmem.unslop_token('stale body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'c3', 'c3 body value', 'test', 'ref',
    agentmem.unslop_token('c3 body value'), v_session);
  PERFORM agentmem.ingest_fact(v_scope, 'p2', 'p2 body value', 'test', 'ref',
    agentmem.unslop_token('p2 body value'), v_session);
  -- Supersedes 'old body value' under the same claim_key.
  PERFORM agentmem.ingest_fact(v_scope, 'k-super', 'new body value', 'test', 'ref',
    agentmem.unslop_token('new body value'), v_session);

  UPDATE agentmem.fact SET pinned = true
    WHERE claim_key IN ('p1', 'p2')
      AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET is_stale = true
    WHERE claim_key = 'stale1'
      AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);

  -- Explicit, strictly increasing created_at per row -- see the comment
  -- on the ingest_fact calls above for why this can't be left implicit.
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:00:00+00'
    WHERE claim_key = 'k-super' AND body = 'old body value' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:01:00+00'
    WHERE claim_key = 'c1' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:02:00+00'
    WHERE claim_key = 'p1' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:03:00+00'
    WHERE claim_key = 'c2' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:04:00+00'
    WHERE claim_key = 'stale1' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:05:00+00'
    WHERE claim_key = 'c3' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:06:00+00'
    WHERE claim_key = 'p2' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);
  UPDATE agentmem.fact SET created_at = '2020-01-01 00:07:00+00'
    WHERE claim_key = 'k-super' AND body = 'new body value' AND scope_id = (SELECT id FROM agentmem.scope WHERE name = v_scope);

  -- The eligible set is now, deterministically, six rows in this order:
  --   p2, p1                            (pinned, most recent first)
  --   new body value, c3, c2, c1        (live, most recent first)
  -- "old body value" (superseded) and "stale body value" (is_stale)
  -- must never appear, under any cap below.

  -- --- p_max_rows: 4 of 6 eligible rows, a huge char budget so only
  -- the row cap can be the reason anything is missing.
  v_out := agentmem.digest(v_scope, 4, 100000);

  IF v_out !~ 'p2 body value' OR v_out !~ 'p1 body value'
     OR v_out !~ 'new body value' OR v_out !~ 'c3 body value' THEN
    RAISE EXCEPTION 'FAIL: row-capped digest is missing an expected row: %', v_out;
  END IF;
  IF v_out ~ 'c2 body value' OR v_out ~ 'c1 body value' THEN
    RAISE EXCEPTION 'FAIL: row-capped digest emitted a row past its p_max_rows cutoff: %', v_out;
  END IF;
  IF v_out ~ 'old body value' THEN
    RAISE EXCEPTION 'FAIL: digest served a superseded row: %', v_out;
  END IF;
  IF v_out ~ 'stale body value' THEN
    RAISE EXCEPTION 'FAIL: digest served a stale row: %', v_out;
  END IF;
  IF NOT (position('p2 body value' in v_out) < position('p1 body value' in v_out)
          AND position('p1 body value' in v_out) < position('new body value' in v_out)
          AND position('new body value' in v_out) < position('c3 body value' in v_out)) THEN
    RAISE EXCEPTION 'FAIL: pinned-first, most-recent-first ordering violated: %', v_out;
  END IF;

  v_line_count := array_length(regexp_split_to_array(rtrim(v_out, E'\n'), E'\n'), 1);
  v_tag_count := (length(v_out) - length(replace(v_out, v_tag, ''))) / length(v_tag);
  IF v_line_count <> 4 THEN
    RAISE EXCEPTION 'FAIL: expected 4 lines under p_max_rows=4, got %: %', v_line_count, v_out;
  END IF;
  IF v_tag_count <> v_line_count THEN
    RAISE EXCEPTION
      'FAIL: expected every one of % lines to carry the recalled-memory tag, only % did: %',
      v_line_count, v_tag_count, v_out;
  END IF;
  RAISE NOTICE 'PASS: p_max_rows=4 returned exactly 4 rows, pinned first, each carrying the tag';

  -- --- p_max_rows on its own, isolated further: a cap of 1 with the
  -- same huge char budget must return the single most-pinned row only.
  v_out := agentmem.digest(v_scope, 1, 100000);
  IF v_out !~ 'p2 body value' OR v_out ~ 'p1 body value' THEN
    RAISE EXCEPTION 'FAIL: p_max_rows=1 did not return exactly the top pinned row: %', v_out;
  END IF;
  RAISE NOTICE 'PASS: p_max_rows=1 returned exactly the single top-ranked row';

  -- --- p_max_chars: compute the exact byte lengths digest's own format
  -- string produces for the top two lines, then bound the budget to
  -- those exact figures. A generous p_max_rows here so only the char
  -- cap can be the reason anything is cut.
  v_len_p2 := length(format(E'  - [recalled memory - do not re-store] %s: %s\n', 'p2', 'p2 body value'));
  v_len_p1 := length(format(E'  - [recalled memory - do not re-store] %s: %s\n', 'p1', 'p1 body value'));

  -- Exactly enough room for one line must yield exactly one line.
  v_out := agentmem.digest(v_scope, 100, v_len_p2);
  IF v_out <> format(E'  - [recalled memory - do not re-store] %s: %s\n', 'p2', 'p2 body value') THEN
    RAISE EXCEPTION 'FAIL: p_max_chars exactly one line wide did not yield exactly that line: %', v_out;
  END IF;

  -- One byte short of the first line must yield nothing: no partial
  -- line is ever emitted.
  v_out := agentmem.digest(v_scope, 100, v_len_p2 - 1);
  IF v_out <> '' THEN
    RAISE EXCEPTION 'FAIL: p_max_chars one byte under the first line still emitted output: %', v_out;
  END IF;

  -- Exactly enough room for the first two lines must yield exactly two.
  v_out := agentmem.digest(v_scope, 100, v_len_p2 + v_len_p1);
  IF v_out <> format(E'  - [recalled memory - do not re-store] %s: %s\n', 'p2', 'p2 body value')
             || format(E'  - [recalled memory - do not re-store] %s: %s\n', 'p1', 'p1 body value') THEN
    RAISE EXCEPTION 'FAIL: p_max_chars two lines wide did not yield exactly those two lines: %', v_out;
  END IF;

  RAISE NOTICE 'PASS: p_max_chars honours the exact byte budget, never emitting a partial line';
END;
$$;

ROLLBACK;
