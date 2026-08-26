//! The five memory tools, each a thin translation from its MCP arguments
//! to a `MemoryStore` call and back to an MCP result.
//!
//! Every handler takes `scope` as an argument on every call. None of them
//! reads a field on `self` for it, because there is no such field:
//! `DotsMemory` holds only the store, and the store holds only the pool.

use std::fmt::Write as _;

use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ContentBlock, ServerCapabilities};
use rmcp::{
    model::ServerInfo, tool, tool_handler, tool_router, ErrorData as McpError, ServerHandler,
};
use schemars::JsonSchema;
use serde::Deserialize;
use uuid::Uuid;

use crate::pgerr::retry_on_conflict;
use crate::store::MemoryStore;

/// `source_kind` `ingest_fact` records for a `forget` call. Fixed rather
/// than accepted as an argument: the spec's four ingest gates depend on
/// every retraction being identifiable as one, which a free-form caller
/// value could not guarantee.
const RETRACTION_SOURCE_KIND: &str = "retraction";

/// Parses a session id argument, arriving over JSON as a string rather
/// than as `Uuid` directly: `uuid` carries no `schemars` support to
/// derive an input schema from.
fn parse_session(raw: &str) -> Result<Uuid, McpError> {
    Uuid::parse_str(raw)
        .map_err(|err| McpError::invalid_params(format!("session is not a UUID: {err}"), None))
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RecallArgs {
    /// The memory scope to search, e.g. a repo or project identifier.
    pub scope: String,
    /// The free-text query to run against the scope's stored facts.
    pub query: String,
    /// Maximum number of ranked results to return.
    #[serde(default = "default_k")]
    pub k: i32,
}

fn default_k() -> i32 {
    10
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct RememberArgs {
    /// The memory scope this fact belongs to.
    pub scope: String,
    /// A short stable key identifying the claim being made; a second
    /// `remember` with the same key supersedes the first rather than
    /// sitting beside it.
    pub claim_key: String,
    /// The fact's body text. Must already have passed the unslop cleaning
    /// pass; raw fetched or transcribed text fails the `unslop_token`
    /// gate below.
    pub body: String,
    /// Where this fact came from, e.g. `"user"` or `"agent-observation"`.
    pub source_kind: String,
    /// A reference to the source, e.g. a file path or message id.
    pub source_ref: String,
    /// The token proving `body` passed the unslop cleaning pass. Forwarded
    /// verbatim to `agentmem.ingest_fact`; never fabricated by this
    /// server, so a raw, uncleaned `body` is rejected at the database
    /// regardless of what this server does with the call.
    pub unslop_token: String,
    /// The session this write is attributed to.
    pub session: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ForgetArgs {
    /// The memory scope the retracted claim belongs to.
    pub scope: String,
    /// The claim key being retracted.
    pub claim_key: String,
    /// Why the claim is being retracted, recorded as the fact's body.
    pub body: String,
    /// A reference to what prompted the retraction.
    pub source_ref: String,
    /// The token proving `body` passed the unslop cleaning pass.
    pub unslop_token: String,
    /// The session this retraction is attributed to.
    pub session: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GraphArgs {
    /// The memory scope to walk.
    pub scope: String,
    /// The entity to walk the neighbourhood of.
    pub root: String,
    /// How many hops out from `root` to include.
    #[serde(default = "default_hops")]
    pub hops: i32,
}

fn default_hops() -> i32 {
    1
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SessionNoteArgs {
    /// The id of the fact being cited as read this session.
    pub fact_id: i64,
    /// The session doing the citing.
    pub session: String,
}

/// The MCP server: five tools over one `MemoryStore`. `S` is generic so
/// tests can swap in a fake store without touching the wiring here.
#[derive(Clone)]
pub struct DotsMemory<S> {
    store: S,
}

#[tool_router]
impl<S> DotsMemory<S>
where
    S: MemoryStore + Clone + Send + Sync + 'static,
{
    pub fn new(store: S) -> Self {
        Self { store }
    }

    #[tool(description = "Search a memory scope's stored facts by free-text \
                        query. Returns ranked results, each tagged \
                        [recalled memory - do not re-store]: recalled text \
                        must never be re-submitted to `remember` as though \
                        it were a fresh observation.")]
    pub async fn recall(
        &self,
        Parameters(args): Parameters<RecallArgs>,
    ) -> Result<CallToolResult, McpError> {
        let rows = self
            .store
            .search(&args.scope, &args.query, args.k)
            .await
            .map_err(|err| McpError::internal_error(err.to_string(), None))?;
        let text = if rows.is_empty() {
            "no matching facts [recalled memory - do not re-store]".to_string()
        } else {
            let mut out = String::from("[recalled memory - do not re-store]\n");
            for row in &rows {
                let _ = writeln!(out, "- ({}) {}: {}", row.fact_id, row.claim_key, row.body);
            }
            out
        };
        Ok(CallToolResult::success(vec![ContentBlock::text(text)]))
    }

    #[tool(description = "Record a new fact in a memory scope. `body` must \
                        already have passed the unslop cleaning pass; pass \
                        its `unslop_token` verbatim, never fabricated. A \
                        second `remember` with the same `claim_key` \
                        supersedes the first rather than duplicating it.")]
    pub async fn remember(
        &self,
        Parameters(args): Parameters<RememberArgs>,
    ) -> Result<CallToolResult, McpError> {
        let session = parse_session(&args.session)?;
        let store = self.store.clone();
        let fact_id = retry_on_conflict(|| {
            let store = store.clone();
            let scope = args.scope.clone();
            let claim_key = args.claim_key.clone();
            let body = args.body.clone();
            let source_kind = args.source_kind.clone();
            let source_ref = args.source_ref.clone();
            let unslop_token = args.unslop_token.clone();
            async move {
                store
                    .ingest_fact(
                        &scope,
                        &claim_key,
                        &body,
                        &source_kind,
                        &source_ref,
                        &unslop_token,
                        session,
                    )
                    .await
            }
        })
        .await?;
        Ok(CallToolResult::success(vec![ContentBlock::text(format!(
            "remembered as fact {fact_id}"
        ))]))
    }

    #[tool(description = "Retract a previously remembered claim. Records the \
                        retraction as a new fact with source_kind \
                        \"retraction\" and supersedes the claim being \
                        retracted; the original stays reachable, marked \
                        superseded, rather than being deleted.")]
    pub async fn forget(
        &self,
        Parameters(args): Parameters<ForgetArgs>,
    ) -> Result<CallToolResult, McpError> {
        let session = parse_session(&args.session)?;
        let store = self.store.clone();
        let fact_id = retry_on_conflict(|| {
            let store = store.clone();
            let scope = args.scope.clone();
            let claim_key = args.claim_key.clone();
            let body = args.body.clone();
            let source_ref = args.source_ref.clone();
            let unslop_token = args.unslop_token.clone();
            async move {
                store
                    .ingest_fact(
                        &scope,
                        &claim_key,
                        &body,
                        RETRACTION_SOURCE_KIND,
                        &source_ref,
                        &unslop_token,
                        session,
                    )
                    .await
            }
        })
        .await?;
        Ok(CallToolResult::success(vec![ContentBlock::text(format!(
            "retracted as fact {fact_id}"
        ))]))
    }

    #[tool(description = "Render a memory scope's neighbourhood around one \
                        entity as a Mermaid graph. This is a human-facing \
                        view for looking, never the store and never the \
                        recall format; past roughly forty nodes the \
                        rendering degrades into a hairball.")]
    pub async fn graph(
        &self,
        Parameters(args): Parameters<GraphArgs>,
    ) -> Result<CallToolResult, McpError> {
        let edges = self
            .store
            .subgraph(&args.scope, &args.root, args.hops)
            .await
            .map_err(|err| McpError::internal_error(err.to_string(), None))?;
        if edges.is_empty() {
            return Ok(CallToolResult::success(vec![ContentBlock::text(
                "no edges in this neighbourhood",
            )]));
        }
        let src: Vec<String> = edges.iter().map(|e| e.src.clone()).collect();
        let verb: Vec<String> = edges.iter().map(|e| e.verb.clone()).collect();
        let dst: Vec<String> = edges.iter().map(|e| e.dst.clone()).collect();
        let mermaid = self
            .store
            .edges_to_mermaid(&src, &verb, &dst)
            .await
            .map_err(|err| McpError::internal_error(err.to_string(), None))?;
        Ok(CallToolResult::success(vec![ContentBlock::text(mermaid)]))
    }

    #[tool(description = "Mark a recalled fact as cited by the current \
                        session. Call this after acting on a recalled \
                        fact so the read/write ledger reflects real use.")]
    pub async fn session_note(
        &self,
        Parameters(args): Parameters<SessionNoteArgs>,
    ) -> Result<CallToolResult, McpError> {
        let session = parse_session(&args.session)?;
        self.store
            .cite_fact(args.fact_id, session)
            .await
            .map_err(|err| McpError::internal_error(err.to_string(), None))?;
        Ok(CallToolResult::success(vec![ContentBlock::text(format!(
            "cited fact {}",
            args.fact_id
        ))]))
    }
}

#[tool_handler]
impl<S> ServerHandler for DotsMemory<S>
where
    S: MemoryStore + Clone + Send + Sync + 'static,
{
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "Stateless memory over a Postgres-backed store. Every call \
             carries its own scope; nothing is cached between calls. \
             recall/graph results are tagged [recalled memory - do not \
             re-store] and must never be re-submitted to remember.",
        )
    }
}
