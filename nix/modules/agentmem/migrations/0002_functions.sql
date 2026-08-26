-- agentmem schema, migration 2 of 2.
--
-- The five functions in the design spec's fixed interface contract
-- (section 4), plus the owner-only staleness sweep. Every one of the
-- five runs SECURITY DEFINER: agentmem_mcp holds no table privileges
-- at all (0001_schema.sql), so a function called by that role can only
-- touch a table by running with its owner's rights instead of the
-- caller's. That is also why each sets search_path explicitly rather
-- than trusting the caller's — a SECURITY DEFINER function that does
-- not pin search_path is hijackable by a same-named object earlier on
-- an attacker-controlled path.
--
-- agentmem.ingest_fact is the only statement in this schema that can
-- make a fact row exist. It carries four gates, checked in this order:
--   1. unslop      -- the caller must present the token this schema
--                     derives from the body, proving the text passed
--                     through the cleaning pass rather than being
--                     inserted raw.
--   2. recall echo -- reject a body this session already read back
--                     via cite_fact (recall, gate via the ledger).
--   3. digest echo -- reject a body already live anywhere in scope,
--                     independent of whether this session saw it.
--   4. content address -- reject a duplicate by normalised hash,
--                     across live and superseded rows alike.
-- On success it closes the prior live row for p_claim_key, if one
-- existed, then inserts the new one. If a live row existed when this
-- call started but the close affects zero rows, a concurrent writer
-- won the same race first: raise 40001 SUPERSEDE_LOST so the caller
-- retries instead of forking history.

CREATE FUNCTION agentmem.unslop_token(p_body text) RETURNS text
  LANGUAGE sql STABLE AS
  $$ SELECT encode(sha256(convert_to('unslop:' || p_body, 'UTF8')), 'hex') $$;

CREATE FUNCTION agentmem.ingest_fact(
  p_scope text, p_claim_key text, p_body text,
  p_source_kind text, p_source_ref text,
  p_unslop_token text, p_session uuid
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id      bigint;
  v_hash          bytea;
  v_had_live      boolean;
  v_closed_id     bigint;
  v_new_id        bigint;
  v_provenance_id bigint;
  v_rows          int;
BEGIN
  IF p_unslop_token IS DISTINCT FROM agentmem.unslop_token(p_body) THEN
    RAISE EXCEPTION 'ingest_fact rejected: body did not pass the unslop gate'
      USING ERRCODE = 'AMU01';
  END IF;

  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = p_scope;
  IF v_scope_id IS NULL THEN
    INSERT INTO agentmem.scope (name) VALUES (p_scope) RETURNING id INTO v_scope_id;
  END IF;

  -- fact.session_id and recall.session_id both FK to session(id), and
  -- neither cite_fact nor ingest_fact's fixed signature is given a way
  -- to create that row up front, so each upserts it the first time a
  -- session shows up on either call.
  INSERT INTO agentmem.session (id, scope_id) VALUES (p_session, v_scope_id)
    ON CONFLICT (id) DO NOTHING;

  IF EXISTS (
    SELECT 1 FROM agentmem.recall r
    JOIN agentmem.fact f ON f.id = r.fact_id
    WHERE r.session_id = p_session AND r.action = 'cite' AND f.body = p_body
  ) THEN
    RAISE EXCEPTION 'ingest_fact rejected: this session already recalled that body'
      USING ERRCODE = 'AMR01';
  END IF;

  IF EXISTS (
    SELECT 1 FROM agentmem.fact
    WHERE scope_id = v_scope_id AND superseded_at IS NULL AND body = p_body
  ) THEN
    RAISE EXCEPTION 'ingest_fact rejected: that body is already live in this scope'
      USING ERRCODE = 'AMD01';
  END IF;

  v_hash := agentmem.norm_hash_v1(p_body);
  IF EXISTS (
    SELECT 1 FROM agentmem.fact WHERE scope_id = v_scope_id AND content_hash = v_hash
  ) THEN
    RAISE EXCEPTION 'ingest_fact rejected: duplicate content hash, live or superseded'
      USING ERRCODE = 'AMC01';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM agentmem.fact
    WHERE scope_id = v_scope_id AND claim_key = p_claim_key AND superseded_at IS NULL
  ) INTO v_had_live;

  IF v_had_live THEN
    UPDATE agentmem.fact SET superseded_at = clock_timestamp()
      WHERE scope_id = v_scope_id AND claim_key = p_claim_key AND superseded_at IS NULL
      RETURNING id INTO v_closed_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'ingest_fact: lost the supersession race for claim_key %', p_claim_key
        USING ERRCODE = '40001';
    END IF;
  END IF;

  INSERT INTO agentmem.provenance (kind, ref) VALUES (p_source_kind, p_source_ref)
    ON CONFLICT (kind, ref) DO UPDATE SET kind = EXCLUDED.kind
    RETURNING id INTO v_provenance_id;

  INSERT INTO agentmem.fact
    (scope_id, claim_key, body, source_kind, source_ref, session_id, supersedes)
    VALUES (v_scope_id, p_claim_key, p_body, p_source_kind, p_source_ref, p_session, v_closed_id)
    RETURNING id INTO v_new_id;

  INSERT INTO agentmem.claim_provenance (fact_id, provenance_id) VALUES (v_new_id, v_provenance_id);

  IF v_had_live THEN
    UPDATE agentmem.fact SET superseded_by = v_new_id WHERE id = v_closed_id;
  END IF;

  RETURN v_new_id;
END;
$$;

-- Logs that p_session actively used p_fact, distinct from a fact
-- merely appearing in a digest. Feeds ingest_fact's recall-echo gate
-- and the reads side of the recall/write ratio.
CREATE FUNCTION agentmem.cite_fact(p_fact bigint, p_session uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id bigint;
BEGIN
  SELECT scope_id INTO v_scope_id FROM agentmem.fact WHERE id = p_fact;
  IF v_scope_id IS NULL THEN
    RAISE EXCEPTION 'cite_fact: no such fact %', p_fact USING ERRCODE = '22023';
  END IF;

  INSERT INTO agentmem.session (id, scope_id) VALUES (p_session, v_scope_id)
    ON CONFLICT (id) DO NOTHING;

  INSERT INTO agentmem.recall (scope_id, session_id, fact_id, action)
    VALUES (v_scope_id, p_session, p_fact, 'cite');
END;
$$;

-- The SessionStart outline: live, non-stale, pinned-first rows, capped
-- at p_max_rows and p_max_chars, each line tagged so a re-extraction
-- pass can refuse to re-store it (the mem0 duplication loop this
-- schema exists to close off). Every emitted row logs a 'digest' read.
CREATE FUNCTION agentmem.digest(p_scope text, p_max_rows int, p_max_chars int) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
DECLARE
  v_scope_id bigint;
  v_out      text := '';
  v_chars    int := 0;
  v_row      record;
BEGIN
  SELECT id INTO v_scope_id FROM agentmem.scope WHERE name = p_scope;
  IF v_scope_id IS NULL THEN
    RETURN '';
  END IF;

  FOR v_row IN
    SELECT id, claim_key, body
    FROM agentmem.fact
    WHERE scope_id = v_scope_id AND superseded_at IS NULL AND NOT is_stale
    ORDER BY pinned DESC, created_at DESC
    LIMIT p_max_rows
  LOOP
    DECLARE
      v_line text := format(
        E'  - [recalled memory - do not re-store] %s: %s\n', v_row.claim_key, v_row.body
      );
    BEGIN
      EXIT WHEN v_chars + length(v_line) > p_max_chars;
      v_out := v_out || v_line;
      v_chars := v_chars + length(v_line);
      INSERT INTO agentmem.recall (scope_id, session_id, fact_id, action)
        VALUES (v_scope_id, NULL, v_row.id, 'digest');
    END;
  END LOOP;

  RETURN v_out;
END;
$$;

-- Keyword and trigram search over live facts in one scope. ts_rank_cd
-- covers ordinary keyword overlap; similarity() catches near-matches
-- tsvector misses (typos, partial words). No Slovak text-search
-- configuration exists (design spec section 2), hence 'simple' plus
-- unaccent plus pg_trgm rather than a stemmed dictionary.
CREATE FUNCTION agentmem.search(p_scope text, p_q text, p_k int)
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
  WHERE f.scope_id = v_scope_id AND f.superseded_at IS NULL
    AND (f.body_tsv @@ v_tsq OR f.body % p_q)
  ORDER BY rank DESC
  LIMIT p_k;
END;
$$;

-- A p_hops-bounded walk from p_root over live relations, both origins
-- mixed in the result (design spec section 7). This is the `graph`
-- tool's backing query, not the store and not the injection format:
-- Mermaid is rendered from this result set only when a human asks.
CREATE FUNCTION agentmem.subgraph(p_scope text, p_root text, p_hops int)
RETURNS TABLE(src text, verb text, dst text, depth int, origin text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = agentmem, pg_temp AS $$
  WITH RECURSIVE walk (src, verb, dst, depth, origin) AS (
    SELECT r.src, r.verb, r.dst, 1, r.origin
    FROM agentmem.relation r
    JOIN agentmem.scope s ON s.id = r.scope_id
    WHERE s.name = p_scope AND r.superseded_at IS NULL AND r.src = p_root
    UNION ALL
    SELECT r.src, r.verb, r.dst, w.depth + 1, r.origin
    FROM agentmem.relation r
    JOIN agentmem.scope s ON s.id = r.scope_id
    JOIN walk w ON r.src = w.dst
    WHERE s.name = p_scope AND r.superseded_at IS NULL AND w.depth < p_hops
  )
  SELECT src, verb, dst, depth, origin FROM walk;
$$;

-- The staleness sweep: usage-based decay for `remembered` facts that
-- nobody has cited in 90 days and that have sat live for 30. `derived`
-- edges are never touched here -- their staleness is a rebuild at a
-- commit, per design spec section 7, handled outside this function
-- entirely. Owner-only: no GRANT follows, so only the schema owner
-- (never agentmem_mcp) can invoke it, from a timer unit rather than
-- from a session.
CREATE FUNCTION agentmem._mark_stale() RETURNS void
LANGUAGE sql AS $$
  UPDATE agentmem.fact f SET is_stale = true
  WHERE f.superseded_at IS NULL
    AND NOT f.is_stale
    AND NOT f.pinned
    AND f.created_at < now() - interval '30 days'
    AND NOT EXISTS (
      SELECT 1 FROM agentmem.recall r
      WHERE r.fact_id = f.id AND r.action = 'cite'
        AND r.created_at > now() - interval '90 days'
    );
$$;

REVOKE ALL ON FUNCTION agentmem.ingest_fact FROM PUBLIC;
REVOKE ALL ON FUNCTION agentmem.cite_fact FROM PUBLIC;
REVOKE ALL ON FUNCTION agentmem.digest FROM PUBLIC;
REVOKE ALL ON FUNCTION agentmem.search FROM PUBLIC;
REVOKE ALL ON FUNCTION agentmem.subgraph FROM PUBLIC;
REVOKE ALL ON FUNCTION agentmem._mark_stale FROM PUBLIC;

GRANT EXECUTE ON FUNCTION agentmem.ingest_fact TO agentmem_mcp;
GRANT EXECUTE ON FUNCTION agentmem.cite_fact TO agentmem_mcp;
GRANT EXECUTE ON FUNCTION agentmem.digest TO agentmem_mcp;
GRANT EXECUTE ON FUNCTION agentmem.search TO agentmem_mcp;
GRANT EXECUTE ON FUNCTION agentmem.subgraph TO agentmem_mcp;
-- agentmem._mark_stale() gets no GRANT: owner-only, by design.
