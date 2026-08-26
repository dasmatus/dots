-- Proves fact_live_claim_uk itself, independent of ingest_fact's own
-- retry logic: two fact rows sharing (scope_id, claim_key), both with
-- superseded_at IS NULL, cannot coexist. A concurrent second writer
-- for the same claim fails at the index instead of forking history
-- (design spec section 5).
--
--   psql -d matus -f tests/agentmem/supersession_race.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope_id bigint;
BEGIN
  INSERT INTO agentmem.scope (name) VALUES ('supersession-race-test')
    RETURNING id INTO v_scope_id;

  INSERT INTO agentmem.fact (scope_id, claim_key, body, source_kind, source_ref)
    VALUES (v_scope_id, 'k1', 'first body', 'test', 'ref1');

  BEGIN
    INSERT INTO agentmem.fact (scope_id, claim_key, body, source_kind, source_ref)
      VALUES (v_scope_id, 'k1', 'second body', 'test', 'ref2');
    RAISE EXCEPTION 'FAIL: a second live row for the same claim_key was allowed';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS: second insert errored on fact_live_claim_uk (%)', SQLSTATE;
  END;

  -- Closing the first row first must then allow the second insert:
  -- the index enforces "at most one live row per claim", not
  -- "at most one row ever".
  UPDATE agentmem.fact SET superseded_at = clock_timestamp()
    WHERE scope_id = v_scope_id AND claim_key = 'k1' AND superseded_at IS NULL;

  INSERT INTO agentmem.fact (scope_id, claim_key, body, source_kind, source_ref)
    VALUES (v_scope_id, 'k1', 'second body', 'test', 'ref2');

  RAISE NOTICE 'PASS: insert succeeded once the prior live row was closed';
END;
$$;

ROLLBACK;
