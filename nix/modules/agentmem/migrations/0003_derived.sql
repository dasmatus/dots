-- agentmem schema, migration 3 of 3.
--
-- The `derived` half of design spec section 7: one function that swaps a
-- scope's whole `origin = 'derived'` slice of agentmem.relation inside one
-- transaction, stamped with the commit the extractor read. Derived edges
-- carry no provenance and are never superseded (0001_schema.sql's
-- relation.superseded_at exists for `remembered` rows only) — staleness
-- for them is a rebuild, never a correction, so this function deletes the
-- old set and inserts the new one rather than diffing.
--
-- Owner-only, like agentmem._mark_stale in 0002_functions.sql: no GRANT
-- follows, and this is invoked by `nix run .#memory-derive` over psql as
-- the cluster owner (peer auth), never by agentmem_mcp. It is not part of
-- the design spec's fixed five-function callable surface (section 4).
CREATE FUNCTION agentmem.rebuild_derived(p_scope text, p_mermaid text, p_sha text) RETURNS int
LANGUAGE plpgsql SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id bigint;
  v_rows     int;
BEGIN
  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = p_scope;
  IF v_scope_id IS NULL THEN
    INSERT INTO agentmem.scope (name) VALUES (p_scope) RETURNING id INTO v_scope_id;
  END IF;

  DELETE FROM agentmem.relation WHERE scope_id = v_scope_id AND origin = 'derived';

  INSERT INTO agentmem.relation (scope_id, src, verb, dst, origin, src_sha)
  SELECT v_scope_id, src, verb, dst, 'derived', p_sha
  FROM agentmem.mermaid_edges(p_mermaid);

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;
