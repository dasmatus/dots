//! The `MemoryStore` trait and its Postgres implementation.
//!
//! Every method takes its scope (and every other argument) as a parameter
//! and returns without retaining anything: no field on `PgStore` holds a
//! scope, a session, or a connection tied to a previous call. A fresh
//! connection is checked out of the pool per call and returned to it
//! immediately after, so two calls in flight at once — even for different
//! scopes — never share mutable state.

use std::future::Future;

use deadpool_postgres::Pool;
use uuid::Uuid;

/// One row of `agentmem.search`.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchRow {
    pub fact_id: i64,
    pub claim_key: String,
    pub body: String,
    pub rank: f32,
}

/// One row of `agentmem.subgraph`.
#[derive(Debug, Clone, PartialEq)]
pub struct SubgraphRow {
    pub src: String,
    pub verb: String,
    pub dst: String,
    pub depth: i32,
    pub origin: String,
}

/// Errors a store call can produce, wrapping the two failure sources a
/// pooled query can hit: checking out a connection, and running on one.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("connection pool error: {0}")]
    Pool(#[from] deadpool_postgres::PoolError),
    #[error("database error: {0}")]
    Db(#[from] tokio_postgres::Error),
}

/// The `agentmem` functions the MCP tools call, one method each: the five
/// from the spec's fixed interface contract plus `note_session`, added in
/// migration 0004 to fill in `agentmem.session.summary`.
///
/// No method here accepts or returns anything that could accumulate
/// between calls: every argument arrives fresh from the tool invocation,
/// and every implementor must open its own connection per call rather
/// than pinning one to a scope.
///
/// Every method spells out its return type as `impl Future<...> + Send`
/// rather than using `async fn` sugar: the `#[tool]` macro on the MCP
/// handlers boxes each call into a `Send` future, and plain `async fn` in
/// a trait makes no `Send` guarantee for callers generic over the trait.
pub trait MemoryStore {
    /// `agentmem.search(p_scope, p_q, p_k)` — full-text plus trigram recall.
    fn search<'a>(
        &'a self,
        scope: &'a str,
        q: &'a str,
        k: i32,
    ) -> impl Future<Output = Result<Vec<SearchRow>, StoreError>> + Send + 'a;

    /// `agentmem.ingest_fact(...)` — the only path a row can be written
    /// through; used for both `remember` and `forget`.
    #[allow(clippy::too_many_arguments)]
    fn ingest_fact<'a>(
        &'a self,
        scope: &'a str,
        claim_key: &'a str,
        body: &'a str,
        source_kind: &'a str,
        source_ref: &'a str,
        unslop_token: &'a str,
        session: Uuid,
    ) -> impl Future<Output = Result<i64, StoreError>> + Send + 'a;

    /// `agentmem.cite_fact(p_fact, p_session)` — marks a fact as read this
    /// session; backs the `cite_fact` tool.
    fn cite_fact(
        &self,
        fact: i64,
        session: Uuid,
    ) -> impl Future<Output = Result<(), StoreError>> + Send + '_;

    /// `agentmem.subgraph(p_scope, p_root, p_hops)` — the edge list a
    /// `graph` call renders to Mermaid.
    fn subgraph<'a>(
        &'a self,
        scope: &'a str,
        root: &'a str,
        hops: i32,
    ) -> impl Future<Output = Result<Vec<SubgraphRow>, StoreError>> + Send + 'a;

    /// `agentmem.edges_to_mermaid(src, verb, dst)` — renders the edge list
    /// `subgraph` returned into the Mermaid text `graph` hands back.
    fn edges_to_mermaid<'a>(
        &'a self,
        src: &'a [String],
        verb: &'a [String],
        dst: &'a [String],
    ) -> impl Future<Output = Result<String, StoreError>> + Send + 'a;

    /// `agentmem.note_session(p_session, p_scope, p_summary, p_files,
    /// p_decisions, p_unfinished, p_unslop_token)` — upserts the one
    /// distilled summary row a session gets, replacing rather than
    /// appending on a second call; backs the `note_session` tool.
    #[allow(clippy::too_many_arguments)]
    fn note_session<'a>(
        &'a self,
        session: Uuid,
        scope: &'a str,
        summary: &'a str,
        files: &'a [String],
        decisions: &'a str,
        unfinished: &'a str,
        unslop_token: &'a str,
    ) -> impl Future<Output = Result<(), StoreError>> + Send + 'a;
}

/// A `MemoryStore` backed by a `deadpool_postgres::Pool`.
///
/// Holds only the pool. Nothing else survives between calls.
#[derive(Clone)]
pub struct PgStore {
    pool: Pool,
}

impl PgStore {
    #[must_use]
    pub fn new(pool: Pool) -> Self {
        Self { pool }
    }
}

impl MemoryStore for PgStore {
    async fn search(&self, scope: &str, q: &str, k: i32) -> Result<Vec<SearchRow>, StoreError> {
        let client = self.pool.get().await?;
        let rows = client
            .query(
                "SELECT fact_id, claim_key, body, rank FROM agentmem.search($1, $2, $3)",
                &[&scope, &q, &k],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| SearchRow {
                fact_id: row.get("fact_id"),
                claim_key: row.get("claim_key"),
                body: row.get("body"),
                rank: row.get("rank"),
            })
            .collect())
    }

    async fn ingest_fact(
        &self,
        scope: &str,
        claim_key: &str,
        body: &str,
        source_kind: &str,
        source_ref: &str,
        unslop_token: &str,
        session: Uuid,
    ) -> Result<i64, StoreError> {
        let client = self.pool.get().await?;
        let row = client
            .query_one(
                "SELECT agentmem.ingest_fact($1, $2, $3, $4, $5, $6, $7)",
                &[
                    &scope,
                    &claim_key,
                    &body,
                    &source_kind,
                    &source_ref,
                    &unslop_token,
                    &session,
                ],
            )
            .await?;
        Ok(row.get(0))
    }

    async fn cite_fact(&self, fact: i64, session: Uuid) -> Result<(), StoreError> {
        let client = self.pool.get().await?;
        client
            .execute("SELECT agentmem.cite_fact($1, $2)", &[&fact, &session])
            .await?;
        Ok(())
    }

    async fn subgraph(
        &self,
        scope: &str,
        root: &str,
        hops: i32,
    ) -> Result<Vec<SubgraphRow>, StoreError> {
        let client = self.pool.get().await?;
        let rows = client
            .query(
                "SELECT src, verb, dst, depth, origin FROM agentmem.subgraph($1, $2, $3)",
                &[&scope, &root, &hops],
            )
            .await?;
        Ok(rows
            .iter()
            .map(|row| SubgraphRow {
                src: row.get("src"),
                verb: row.get("verb"),
                dst: row.get("dst"),
                depth: row.get("depth"),
                origin: row.get("origin"),
            })
            .collect())
    }

    async fn edges_to_mermaid(
        &self,
        src: &[String],
        verb: &[String],
        dst: &[String],
    ) -> Result<String, StoreError> {
        let client = self.pool.get().await?;
        let row = client
            .query_one(
                "SELECT agentmem.edges_to_mermaid($1, $2, $3)",
                &[&src, &verb, &dst],
            )
            .await?;
        Ok(row.get(0))
    }

    async fn note_session(
        &self,
        session: Uuid,
        scope: &str,
        summary: &str,
        files: &[String],
        decisions: &str,
        unfinished: &str,
        unslop_token: &str,
    ) -> Result<(), StoreError> {
        let client = self.pool.get().await?;
        client
            .execute(
                "SELECT agentmem.note_session($1, $2, $3, $4, $5, $6, $7)",
                &[
                    &session,
                    &scope,
                    &summary,
                    &files,
                    &decisions,
                    &unfinished,
                    &unslop_token,
                ],
            )
            .await?;
        Ok(())
    }
}
