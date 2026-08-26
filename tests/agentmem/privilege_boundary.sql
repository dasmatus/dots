-- Proves agentmem_mcp holds zero table privileges in the agentmem
-- schema: it gets USAGE on the schema and EXECUTE on the five API
-- functions only, and nothing else (design spec section 4 — there is
-- no GRANT ... ON TABLE anywhere in either migration). Every direct
-- table statement below must fail with insufficient_privilege
-- (SQLSTATE 42501), never with an authentication error, since peer
-- auth already let the role connect.
--
-- Must run as a role permitted to SET ROLE agentmem_mcp (the schema
-- owner, e.g. matus):
--   psql -d matus -f tests/agentmem/privilege_boundary.sql
\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  SET ROLE agentmem_mcp;

  BEGIN
    INSERT INTO agentmem.fact (scope_id, claim_key, body, source_kind, source_ref)
      VALUES (1, 'x', 'y', 'z', 'w');
    RAISE EXCEPTION 'FAIL: agentmem_mcp inserted into agentmem.fact directly';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: direct INSERT on agentmem.fact denied by privilege (%)', SQLSTATE;
  END;

  BEGIN
    PERFORM 1 FROM agentmem.fact;
    RAISE EXCEPTION 'FAIL: agentmem_mcp read agentmem.fact directly';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: direct SELECT on agentmem.fact denied by privilege (%)', SQLSTATE;
  END;

  BEGIN
    PERFORM agentmem._mark_stale();
    RAISE EXCEPTION 'FAIL: agentmem_mcp called owner-only agentmem._mark_stale()';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: agentmem._mark_stale() denied to agentmem_mcp (%)', SQLSTATE;
  END;

  RESET ROLE;
END;
$$;

ROLLBACK;
