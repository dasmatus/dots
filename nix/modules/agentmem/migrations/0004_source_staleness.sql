-- agentmem schema, migration 4 of 4.
--
-- Closes a gap left open by 0002_functions.sql: `agentmem._mark_stale`
-- decayed a `remembered` fact by age and citation count, but never
-- checked the one thing the design spec's section 7 actually promises --
-- "a fact must not outlive the file it came from". A fact whose
-- source_kind is 'file' and whose source_ref has been deleted, renamed
-- or moved out from under it is now swept the same way: is_stale flips
-- to true, the row is never deleted (supersession and the audit trail in
-- claim_provenance both need it to still exist), and it drops out of
-- both agentmem.digest and agentmem.search, which is why the second half
-- of this file also fixes agentmem.search -- it filtered is_stale nowhere
-- at all, so a fact the sweep had already retired was still being served
-- to a live query.
--
-- pg_agentmem's agentmem.file_exists_v1(text) (rust/pg-agentmem, plan 1)
-- backs the check. It is deliberately not IMMUTABLE, unlike this crate's
-- other three functions: whether a path exists is exactly the external
-- state this sweep exists to notice changing. It is also not granted to
-- agentmem_mcp below, for the same reason agentmem._mark_stale itself
-- carries no GRANT -- letting the MCP role probe arbitrary server-side
-- paths for existence is a mild oracle this schema has no need to offer.
REVOKE ALL ON FUNCTION agentmem.file_exists_v1(text) FROM PUBLIC;

-- CREATE OR REPLACE keeps the existing owner-only ACL (0002_functions.sql
-- grants nothing on this function to anyone), so no re-REVOKE is needed
-- here the way it is above for the pgrx-created file_exists_v1, which
-- ships PUBLIC EXECUTE by default like this crate's other functions.
CREATE OR REPLACE FUNCTION agentmem._mark_stale() RETURNS void
LANGUAGE sql AS $$
  UPDATE agentmem.fact f SET is_stale = true
  WHERE f.superseded_at IS NULL
    AND NOT f.is_stale
    AND NOT f.pinned
    AND (
      -- Usage-based decay: sat live 30 days, uncited in the last 90.
      (
        f.created_at < now() - interval '30 days'
        AND NOT EXISTS (
          SELECT 1 FROM agentmem.recall r
          WHERE r.fact_id = f.id AND r.action = 'cite'
            AND r.created_at > now() - interval '90 days'
        )
      )
      -- Source-based decay: the file this fact cites is gone. Pins
      -- exempt a fact from both branches, per the NOT f.pinned guard
      -- above -- a pinned fact survives its source file disappearing
      -- exactly as it survives citation silence.
      OR (f.source_kind = 'file' AND NOT agentmem.file_exists_v1(f.source_ref))
    );
$$;

-- agentmem.digest already filtered "AND NOT is_stale" from 0002 onward,
-- so a swept-stale row already dropped out of the SessionStart outline.
-- agentmem.search never did: CREATE OR REPLACE here adds the same guard,
-- keeping the fixed signature (design spec section 4) and the existing
-- GRANT to agentmem_mcp, which CREATE OR REPLACE preserves untouched.
CREATE OR REPLACE FUNCTION agentmem.search(p_scope text, p_q text, p_k int)
RETURNS TABLE(fact_id bigint, claim_key text, body text, rank real)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id bigint;
  v_tsq      tsquery;
BEGIN
  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = p_scope;
  IF v_scope_id IS NULL THEN
    RETURN;
  END IF;

  v_tsq := plainto_tsquery('simple', agentmem.f_unaccent(p_q));

  RETURN QUERY
  SELECT f.id, f.claim_key, f.body,
         (ts_rank_cd(f.body_tsv, v_tsq) + similarity(f.body, p_q))::real AS rank
  FROM agentmem.fact f
  WHERE f.scope_id = v_scope_id AND f.superseded_at IS NULL AND NOT f.is_stale
    AND (f.body_tsv @@ v_tsq OR f.body % p_q)
  ORDER BY rank DESC
  LIMIT p_k;
END;
$$;
