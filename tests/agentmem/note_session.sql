-- Proves agentmem.note_session (0004_note_session.sql):
--   1. a second call for the same session REPLACES the summary, leaving
--      exactly one agentmem.session row whose summary is the second body;
--   2. a call for a second session leaves two session rows, one per
--      session, each with its own summary;
--   3. a summary without a matching unslop token is rejected, same
--      SQLSTATE AMU01 as ingest_fact's own gate 1.
--
--   psql -d matus -f tests/agentmem/note_session.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope    text := 'note-session-test';
  v_s1       uuid := gen_random_uuid();
  v_s2       uuid := gen_random_uuid();
  v_summary  text;
  v_count    int;
BEGIN
  -- Gate: a summary without the matching unslop token is rejected.
  BEGIN
    PERFORM agentmem.note_session(
      v_s1, v_scope, 'first summary', ARRAY['a.rs'], 'decided x', 'left y unfinished',
      'wrong-token'
    );
    RAISE EXCEPTION 'FAIL: note_session accepted a summary without a matching unslop token';
  EXCEPTION WHEN SQLSTATE 'AMU01' THEN
    RAISE NOTICE 'PASS: bad unslop token rejected (%)', SQLERRM;
  END;

  -- First call for v_s1.
  PERFORM agentmem.note_session(
    v_s1, v_scope, 'first summary', ARRAY['a.rs'], 'decided x', 'left y unfinished',
    agentmem.unslop_token('first summary')
  );

  SELECT count(*) INTO v_count FROM agentmem.session WHERE id = v_s1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly one session row for v_s1 after the first call, found %', v_count;
  END IF;

  -- Second call for the same session must REPLACE, not append.
  PERFORM agentmem.note_session(
    v_s1, v_scope, 'second summary', ARRAY['b.rs'], 'decided y', 'left z unfinished',
    agentmem.unslop_token('second summary')
  );

  SELECT count(*) INTO v_count FROM agentmem.session WHERE id = v_s1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: a second note_session call for v_s1 forked into % rows instead of replacing', v_count;
  END IF;

  SELECT summary INTO v_summary FROM agentmem.session WHERE id = v_s1;
  IF v_summary NOT LIKE 'second summary%' THEN
    RAISE EXCEPTION 'FAIL: v_s1''s summary was not replaced by the second call: %', v_summary;
  END IF;
  IF v_summary LIKE '%first summary%' THEN
    RAISE EXCEPTION 'FAIL: v_s1''s summary still carries the first call''s body: %', v_summary;
  END IF;
  RAISE NOTICE 'PASS: one row for v_s1, summary replaced by the second call';

  -- A second session leaves a second row, not a merge into the first.
  PERFORM agentmem.note_session(
    v_s2, v_scope, 'a wholly different summary', ARRAY[]::text[], 'decided z', 'nothing left',
    agentmem.unslop_token('a wholly different summary')
  );

  SELECT count(*) INTO v_count FROM agentmem.session WHERE id IN (v_s1, v_s2);
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: expected two session rows across v_s1 and v_s2, found %', v_count;
  END IF;

  SELECT summary INTO v_summary FROM agentmem.session WHERE id = v_s1;
  IF v_summary NOT LIKE 'second summary%' THEN
    RAISE EXCEPTION 'FAIL: v_s2''s note_session call disturbed v_s1''s summary: %', v_summary;
  END IF;
  RAISE NOTICE 'PASS: two sessions, two rows, each with its own summary';
END;
$$;

ROLLBACK;
