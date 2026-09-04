-- agentmem schema, migration 7.
--
-- Backs the Stop hook in nix/home/ai/claude.nix. That branch used to print
-- "nothing durable was recorded this session" unconditionally: it ran no
-- query at all, so it said the same thing after a session that stored ten
-- facts as after one that stored none. A message that cannot be wrong
-- carries no information, and an agent that reads it as a report writes a
-- second fact beside the one it already wrote.
--
-- The predicate is session-keyed, not scope-keyed. agentmem.fact and
-- agentmem.relation both carry a nullable session_id referencing
-- agentmem.session (0001_schema.sql), and that column is the only thing
-- separating "this session wrote something" from "this scope has facts in
-- it". The second is true almost always and answers nothing.
--
-- Only 'remembered' relations count. A 'derived' edge comes from
-- agentmem.rebuild_derived reading the checkout rather than from anything
-- a session learned, and carries src_sha instead of a session (design
-- spec section 7). Counting it would let a graph rebuild silence the
-- nudge for a session that wrote nothing.
--
-- Superseded and stale rows still count. Both mean the session did write
-- something durable; what happened to the row afterwards is a separate
-- question from whether the nudge has anything to complain about.
--
-- STABLE rather than IMMUTABLE, because the answer changes as the session
-- writes. SECURITY DEFINER with a pinned search_path, matching every
-- function in 0002_functions.sql. No GRANT to agentmem_mcp: the only
-- caller is the Stop hook, which connects as the schema owner over peer
-- auth and therefore needs none, and widening the MCP role's reach to a
-- function it never calls buys nothing.
CREATE FUNCTION agentmem.session_wrote(p_session uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM agentmem.fact WHERE session_id = p_session
    UNION ALL
    SELECT 1 FROM agentmem.relation
    WHERE session_id = p_session AND origin = 'remembered'
  );
$$;

REVOKE ALL ON FUNCTION agentmem.session_wrote(uuid) FROM PUBLIC;
