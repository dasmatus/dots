-- agentmem schema, migration 4.
--
-- Closes the gap left by 0001_schema.sql: agentmem.session.summary is a
-- column with nothing writing it. Design spec section 11 is explicit that
-- exactly one distilled summary row is stored per session, and the
-- session primary key already gives that for free -- this migration adds
-- the one function allowed to fill it in.
--
-- agentmem.note_session runs the same unslop gate agentmem.ingest_fact
-- uses, against p_summary specifically: a session summary is prose read
-- back into context every session, which is exactly the case the gate
-- exists for. p_files, p_decisions and p_unfinished are folded into the
-- stored text alongside it -- there is no second column to put them in --
-- but the gate is checked against p_summary alone, matching the token a
-- caller can actually compute without reproducing this function's
-- formatting.
--
-- Upserts on agentmem.session's primary key (id), so a second call for
-- the same session replaces the summary rather than appending to it: one
-- summary per session by construction, same as ingest_fact's four gates
-- are the only way a fact row comes into being. SECURITY DEFINER and a
-- pinned search_path for the same reason as every function in
-- 0002_functions.sql -- agentmem_mcp holds no table privileges, so this
-- can only touch agentmem.session by running with its owner's rights.
CREATE FUNCTION agentmem.note_session(
  p_session uuid, p_scope text, p_summary text,
  p_files text[], p_decisions text, p_unfinished text,
  p_unslop_token text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id bigint;
  v_body     text;
BEGIN
  IF p_unslop_token IS DISTINCT FROM agentmem.unslop_token(p_summary) THEN
    RAISE EXCEPTION 'note_session rejected: summary did not pass the unslop gate'
      USING ERRCODE = 'AMU01';
  END IF;

  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = p_scope;
  IF v_scope_id IS NULL THEN
    INSERT INTO agentmem.scope (name) VALUES (p_scope) RETURNING id INTO v_scope_id;
  END IF;

  v_body := format(
    E'%s\n\nFiles touched: %s\nDecisions: %s\nUnfinished: %s',
    p_summary,
    COALESCE(array_to_string(p_files, ', '), ''),
    COALESCE(p_decisions, ''),
    COALESCE(p_unfinished, '')
  );

  -- ON CONFLICT DO UPDATE, not DO NOTHING like ingest_fact's and
  -- cite_fact's session upserts: those two only need the row to exist so
  -- their own FK reference resolves, but this call's whole point is
  -- replacing the summary, including on a session row a prior
  -- ingest_fact or cite_fact already created with scope_id set and
  -- summary NULL.
  INSERT INTO agentmem.session (id, scope_id, summary)
    VALUES (p_session, v_scope_id, v_body)
  ON CONFLICT (id) DO UPDATE SET summary = EXCLUDED.summary;
END;
$$;

REVOKE ALL ON FUNCTION agentmem.note_session FROM PUBLIC;
GRANT EXECUTE ON FUNCTION agentmem.note_session TO agentmem_mcp;
