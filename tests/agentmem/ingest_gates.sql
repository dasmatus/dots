-- Exercises all four agentmem.ingest_fact gates, one rejection per
-- gate in the order they run, then a fifth call passing all four
-- (design spec section 4):
--   1. unslop        -- wrong token
--   2. recall echo   -- body already cite_fact'd this session
--   3. digest echo   -- body already live elsewhere in scope
--   4. content address -- same normalised hash as a superseded row
--
--   psql -d matus -f tests/agentmem/ingest_gates.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_scope  text := 'ingest-gates-test';
  v_s1     uuid := gen_random_uuid();
  v_s2     uuid := gen_random_uuid();
  v_s3     uuid := gen_random_uuid();
  v_s4     uuid := gen_random_uuid();
  v_s5     uuid := gen_random_uuid();
  v_fact1  bigint;
  v_new    bigint;
BEGIN
  -- Setup: one live fact, cited by v_s1.
  v_fact1 := agentmem.ingest_fact(
    v_scope, 'k1', 'body one', 'test', 'ref1',
    agentmem.unslop_token('body one'), v_s1
  );
  PERFORM agentmem.cite_fact(v_fact1, v_s1);

  -- Gate 1: unslop token.
  BEGIN
    PERFORM agentmem.ingest_fact(v_scope, 'k9', 'gate one body', 'test', 'ref', 'wrong-token', v_s1);
    RAISE EXCEPTION 'FAIL gate 1 (unslop): bad token was accepted';
  EXCEPTION WHEN SQLSTATE 'AMU01' THEN
    RAISE NOTICE 'PASS gate 1 (unslop): %', SQLERRM;
  END;

  -- Gate 2: recall echo -- v_s1 already cite_fact'd "body one".
  BEGIN
    PERFORM agentmem.ingest_fact(
      v_scope, 'k2', 'body one', 'test', 'ref1',
      agentmem.unslop_token('body one'), v_s1
    );
    RAISE EXCEPTION 'FAIL gate 2 (recall echo): recalled body was re-ingested';
  EXCEPTION WHEN SQLSTATE 'AMR01' THEN
    RAISE NOTICE 'PASS gate 2 (recall echo): %', SQLERRM;
  END;

  -- Gate 3: digest echo -- "body one" is still live, but v_s2 never
  -- recalled it, so only the live-body check can catch this one.
  BEGIN
    PERFORM agentmem.ingest_fact(
      v_scope, 'k3', 'body one', 'test', 'ref1',
      agentmem.unslop_token('body one'), v_s2
    );
    RAISE EXCEPTION 'FAIL gate 3 (digest echo): live body was re-ingested';
  EXCEPTION WHEN SQLSTATE 'AMD01' THEN
    RAISE NOTICE 'PASS gate 3 (digest echo): %', SQLERRM;
  END;

  -- Retire "body one" so gate 3 no longer applies to it.
  PERFORM agentmem.ingest_fact(
    v_scope, 'k1', 'body two (correction)', 'test', 'ref2',
    agentmem.unslop_token('body two (correction)'), v_s3
  );

  -- Gate 4: content address -- "body one" is superseded, not live, so
  -- only the hash check (live + superseded) can catch this one.
  BEGIN
    PERFORM agentmem.ingest_fact(
      v_scope, 'k4', 'body one', 'test', 'ref1',
      agentmem.unslop_token('body one'), v_s4
    );
    RAISE EXCEPTION 'FAIL gate 4 (content address): superseded body was re-ingested';
  EXCEPTION WHEN SQLSTATE 'AMC01' THEN
    RAISE NOTICE 'PASS gate 4 (content address): %', SQLERRM;
  END;

  -- Fifth call: a genuinely new claim and body passes all four gates.
  v_new := agentmem.ingest_fact(
    v_scope, 'k5', 'a brand new claim never seen before', 'test', 'ref5',
    agentmem.unslop_token('a brand new claim never seen before'), v_s5
  );
  IF v_new IS NULL THEN
    RAISE EXCEPTION 'FAIL: fifth call did not return a new fact id';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM agentmem.fact
    WHERE id = v_new AND superseded_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: fifth call''s row is not live';
  END IF;

  RAISE NOTICE 'PASS: fifth call created one new live row (fact id %)', v_new;
END;
$$;

ROLLBACK;
