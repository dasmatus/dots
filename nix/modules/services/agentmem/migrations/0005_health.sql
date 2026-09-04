-- agentmem schema, migration 5.
--
-- agentmem.health(): makes the kill criterion in design spec section 10
-- actually checkable instead of arguable. The section commits to deleting
-- this store outright if reads do not exceed writes within a month of the
-- first stored row -- this is the query that renders that judgment, rather
-- than leaving it to be eyeballed off raw tables.
--
-- Reads come from the recall ledger (agentmem.recall, both the 'digest'
-- and 'cite' actions logged there); writes are agentmem.fact rows created
-- inside the window. Both are windowed by p_since; the oldest-fact age is
-- not -- it looks at every live-or-superseded row ever inserted, because
-- the one-month clock in section 10 starts at the first stored row, not at
-- the edge of whatever window the caller passes.
--
-- SECURITY DEFINER with search_path pinned, matching every function in
-- 0002_functions.sql: agentmem_mcp holds no table privileges anywhere in
-- this schema (0001_schema.sql), so a function it calls can only read
-- agentmem.recall and agentmem.fact by running under the owner's rights.
-- An unpinned search_path on a SECURITY DEFINER function is hijackable by
-- a same-named object earlier on an attacker-controlled path, hence the
-- explicit SET here even though this function only ever reads.
CREATE FUNCTION agentmem.health(p_since interval DEFAULT '30 days')
RETURNS TABLE (
  reads            bigint,
  writes           bigint,
  ratio            numeric,
  oldest_fact_age  interval,
  live_facts       bigint,
  superseded_facts bigint,
  stale_facts      bigint,
  verdict          text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_reads      bigint;
  v_writes     bigint;
  v_ratio      numeric;
  v_oldest     interval;
  v_live       bigint;
  v_superseded bigint;
  v_stale      bigint;
  v_verdict    text;
BEGIN
  SELECT count(*) INTO v_reads
  FROM agentmem.recall
  WHERE created_at > now() - p_since;

  SELECT count(*) INTO v_writes
  FROM agentmem.fact
  WHERE created_at > now() - p_since;

  v_ratio := v_reads::numeric / NULLIF(v_writes, 0);

  SELECT now() - min(created_at) INTO v_oldest FROM agentmem.fact;

  SELECT count(*) FILTER (WHERE superseded_at IS NULL),
         count(*) FILTER (WHERE superseded_at IS NOT NULL),
         count(*) FILTER (WHERE is_stale)
    INTO v_live, v_superseded, v_stale
  FROM agentmem.fact;

  -- The verdict states the same comparison section 10 does: reads against
  -- writes, in plain language, so a caller does not have to interpret the
  -- ratio itself. A zero-write window is not a verdict either way -- there
  -- is nothing yet to judge -- and the losing case names the design's own
  -- commitment rather than merely reporting a number.
  IF v_writes = 0 THEN
    v_verdict := format(
      'no facts were written in the last %s; nothing to judge yet.', p_since
    );
  ELSIF v_reads > v_writes THEN
    v_verdict := format(
      'earning its keep: %s reads against %s writes in the last %s.',
      v_reads, v_writes, p_since
    );
  ELSE
    v_verdict := format(
      'not earning its keep: %s reads against %s writes in the last %s -- '
      || 'per design spec section 10, if this still holds a month past the '
      || 'oldest stored row, delete this store rather than tune it.',
      v_reads, v_writes, p_since
    );
  END IF;

  RETURN QUERY
  SELECT v_reads, v_writes, v_ratio, v_oldest, v_live, v_superseded, v_stale, v_verdict;
END;
$$;

REVOKE ALL ON FUNCTION agentmem.health FROM PUBLIC;
GRANT EXECUTE ON FUNCTION agentmem.health TO agentmem_mcp;
