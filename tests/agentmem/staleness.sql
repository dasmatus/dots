-- Exercises the file-existence half of the staleness sweep added in
-- 0006_source_staleness.sql: a `remembered` fact must not outlive the
-- file its source_ref names (design spec section 7). agentmem._mark_stale
-- already covered usage-based decay before this migration; this file
-- covers the branch that checks agentmem.file_exists_v1(source_ref) for
-- source_kind = 'file' rows, freshly inserted so the 30-day/90-day
-- usage-decay branch cannot be the one doing the work.
--
-- Also proves the sweep's effect actually reaches the two read paths
-- that promise to honour is_stale: agentmem.digest and (as of
-- 0006_source_staleness.sql, which added the guard) agentmem.search.
-- And proves the sweep never deletes: a stale row is excluded from both,
-- not removed from agentmem.fact.
--
--   psql -d matus -f tests/agentmem/staleness.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope       text := 'staleness-test';
  v_session     uuid := gen_random_uuid();
  v_real_path   text := current_setting('data_directory');
  v_missing     text := '/nonexistent/agentmem-staleness-test/should-not-exist';
  v_live_id     bigint;
  v_missing_id  bigint;
  v_out         text;
  v_hits        bigint[];
BEGIN
  IF agentmem.file_exists_v1(v_real_path) IS NOT true THEN
    RAISE EXCEPTION 'FAIL: test setup assumption broken, % does not exist', v_real_path;
  END IF;
  IF agentmem.file_exists_v1(v_missing) IS NOT false THEN
    RAISE EXCEPTION 'FAIL: test setup assumption broken, % unexpectedly exists', v_missing;
  END IF;

  v_live_id := agentmem.ingest_fact(
    v_scope, 'k-live', 'stalenessmarker present in a real file body', 'file', v_real_path,
    agentmem.unslop_token('stalenessmarker present in a real file body'), v_session
  );
  v_missing_id := agentmem.ingest_fact(
    v_scope, 'k-missing', 'stalenessmarker present in a missing file body', 'file', v_missing,
    agentmem.unslop_token('stalenessmarker present in a missing file body'), v_session
  );

  -- Before the sweep runs, both rows are live and neither is stale.
  IF EXISTS (SELECT 1 FROM agentmem.fact WHERE id IN (v_live_id, v_missing_id) AND is_stale) THEN
    RAISE EXCEPTION 'FAIL: a fact was already stale before the sweep ran';
  END IF;

  PERFORM agentmem._mark_stale();

  -- The row whose source file is still there must stay live.
  IF EXISTS (SELECT 1 FROM agentmem.fact WHERE id = v_live_id AND is_stale) THEN
    RAISE EXCEPTION 'FAIL: sweep marked a fact stale whose source file still exists (%)', v_real_path;
  END IF;
  RAISE NOTICE 'PASS: a fact whose source_ref file exists stays live after the sweep';

  -- The row whose source file is gone must now be stale.
  IF NOT EXISTS (SELECT 1 FROM agentmem.fact WHERE id = v_missing_id AND is_stale) THEN
    RAISE EXCEPTION 'FAIL: sweep did not mark stale a fact whose source file is missing (%)', v_missing;
  END IF;
  RAISE NOTICE 'PASS: a fact whose source_ref file is missing is marked stale by the sweep';

  -- It must drop out of digest.
  v_out := agentmem.digest(v_scope, 100, 100000);
  IF v_out ~ 'missing file body' THEN
    RAISE EXCEPTION 'FAIL: a stale fact still appeared in digest: %', v_out;
  END IF;
  IF v_out !~ 'real file body' THEN
    RAISE EXCEPTION 'FAIL: the still-live fact was missing from digest: %', v_out;
  END IF;
  RAISE NOTICE 'PASS: the stale fact dropped out of digest; the live one did not';

  -- It must drop out of search, too.
  SELECT array_agg(fact_id) INTO v_hits FROM agentmem.search(v_scope, 'stalenessmarker', 10);
  IF v_missing_id = ANY (v_hits) THEN
    RAISE EXCEPTION 'FAIL: a stale fact still appeared in search results: %', v_hits;
  END IF;
  IF NOT (v_live_id = ANY (v_hits)) THEN
    RAISE EXCEPTION 'FAIL: the still-live fact was missing from search results: %', v_hits;
  END IF;
  RAISE NOTICE 'PASS: the stale fact dropped out of search; the live one did not';

  -- Excluded, never deleted: the row is still there, still live
  -- (superseded_at IS NULL), just flagged.
  IF NOT EXISTS (
    SELECT 1 FROM agentmem.fact
    WHERE id = v_missing_id AND is_stale AND superseded_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: the stale fact row was deleted or superseded rather than merely flagged';
  END IF;
  RAISE NOTICE 'PASS: the stale fact row still exists, unsuperseded -- excluded, not deleted';
END;
$$;

ROLLBACK;
