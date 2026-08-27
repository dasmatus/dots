-- Proves agentmem.session_wrote (0007_session_wrote.sql), the predicate
-- the Stop hook in nix/home/claude.nix asks before nudging:
--   1. a session nobody has written for is false;
--   2. a session that ingested a fact is true;
--   3. a sibling session in the same scope stays false, so the answer
--      tracks the session and not the scope it wrote into;
--   4. a session carrying only a 'derived' relation is false, because a
--      graph rebuild is not something a session learned;
--   5. a session carrying a 'remembered' relation is true with no fact;
--   6. a fact that has since been superseded still counts, since the
--      session did write it.
--
--   psql -d matus -f tests/agentmem/session_wrote.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope    text := 'session-wrote-test';
  v_scope_id bigint;
  v_writer   uuid := gen_random_uuid();
  v_sibling  uuid := gen_random_uuid();
  v_derived  uuid := gen_random_uuid();
  v_remember uuid := gen_random_uuid();
  v_unknown  uuid := gen_random_uuid();
BEGIN
  -- 1. Nobody has written for this session.
  IF agentmem.session_wrote(v_unknown) THEN
    RAISE EXCEPTION 'FAIL: an unwritten session reported as having written';
  END IF;
  RAISE NOTICE 'PASS: an unwritten session is false';

  -- 2. A session that ingested a fact.
  PERFORM agentmem.ingest_fact(
    v_scope, 'writer-claim', 'the writer session body',
    'agent-observation', 'tests/agentmem/session_wrote.sql',
    agentmem.unslop_token('the writer session body'), v_writer
  );
  IF NOT agentmem.session_wrote(v_writer) THEN
    RAISE EXCEPTION 'FAIL: a session that ingested a fact reported as having written nothing';
  END IF;
  RAISE NOTICE 'PASS: a session that ingested a fact is true';

  -- 3. A sibling session in the same scope is unaffected. This is the
  -- distinction the whole function exists for: the scope now holds a
  -- fact, and a scope-keyed predicate would call the sibling true.
  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = v_scope;
  INSERT INTO agentmem.session (id, scope_id) VALUES (v_sibling, v_scope_id);
  IF agentmem.session_wrote(v_sibling) THEN
    RAISE EXCEPTION 'FAIL: a sibling session inherited the scope''s fact';
  END IF;
  RAISE NOTICE 'PASS: a sibling session in a written-to scope stays false';

  -- 4. A 'derived' relation is a rebuild artefact, not a session's work.
  INSERT INTO agentmem.session (id, scope_id) VALUES (v_derived, v_scope_id);
  INSERT INTO agentmem.relation (scope_id, src, verb, dst, origin, src_sha, session_id)
    VALUES (v_scope_id, 'a', 'calls', 'b', 'derived', 'deadbeef', v_derived);
  IF agentmem.session_wrote(v_derived) THEN
    RAISE EXCEPTION 'FAIL: a derived relation counted as something the session learned';
  END IF;
  RAISE NOTICE 'PASS: a derived relation does not count';

  -- 5. A 'remembered' relation does, with no fact alongside it.
  INSERT INTO agentmem.session (id, scope_id) VALUES (v_remember, v_scope_id);
  INSERT INTO agentmem.relation (scope_id, src, verb, dst, origin, session_id)
    VALUES (v_scope_id, 'c', 'supersedes', 'd', 'remembered', v_remember);
  IF NOT agentmem.session_wrote(v_remember) THEN
    RAISE EXCEPTION 'FAIL: a remembered relation did not count as a durable write';
  END IF;
  RAISE NOTICE 'PASS: a remembered relation counts on its own';

  -- 6. Superseding the writer's fact must not retract the answer.
  PERFORM agentmem.ingest_fact(
    v_scope, 'writer-claim', 'the writer session body, corrected',
    'agent-observation', 'tests/agentmem/session_wrote.sql',
    agentmem.unslop_token('the writer session body, corrected'), v_writer
  );
  IF NOT EXISTS (
    SELECT 1 FROM agentmem.fact
    WHERE session_id = v_writer AND superseded_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: the second ingest_fact did not supersede the first, so case 6 proves nothing';
  END IF;
  IF NOT agentmem.session_wrote(v_writer) THEN
    RAISE EXCEPTION 'FAIL: superseding a fact retracted the session''s write';
  END IF;
  RAISE NOTICE 'PASS: a superseded fact still counts as a write';
END;
$$;

ROLLBACK;
