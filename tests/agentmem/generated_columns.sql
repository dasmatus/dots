-- Proves every generated column under the agentmem schema spells
-- STORED, never PG18's default VIRTUAL (design spec section 4): a
-- virtual generated column cannot be indexed, and CREATE INDEX fails
-- with no earlier warning. Verified against attgenerated in
-- pg_attribute rather than by reading the migration source, so a
-- future edit that drops STORED is caught here even if it still reads
-- correctly.
--
-- Run against a database that already has 0001_schema.sql and
-- 0002_functions.sql applied:
--   psql -d matus -f tests/agentmem/generated_columns.sql
\set ON_ERROR_STOP on

DO $$
DECLARE
  v_non_stored text;
  v_stored_count int;
BEGIN
  SELECT string_agg(c.relname || '.' || a.attname, ', ')
  INTO v_non_stored
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'agentmem'
    AND a.attnum > 0
    AND a.attgenerated <> ''
    AND a.attgenerated <> 's';

  IF v_non_stored IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: non-STORED generated column(s): %', v_non_stored;
  END IF;

  SELECT count(*) INTO v_stored_count
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'agentmem' AND a.attgenerated = 's';

  IF v_stored_count < 3 THEN
    RAISE EXCEPTION
      'FAIL: expected at least 3 STORED generated columns (entity.slug, fact.content_hash, fact.body_tsv), found %',
      v_stored_count;
  END IF;

  RAISE NOTICE 'PASS: % STORED generated column(s) in agentmem, none VIRTUAL', v_stored_count;
END;
$$;
