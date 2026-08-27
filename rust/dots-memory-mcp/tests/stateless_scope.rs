//! Proves two concurrent tool calls under different scopes never see each
//! other's data.
//!
//! `FakeStore` is not a mock that only proves the mock works: it holds
//! real, scope-keyed state — a `Mutex<HashMap<scope, Vec<(claim_key,
//! body)>>>` — and a deliberate delay on the scope that writes first, so
//! the second call's write and read interleave with the first call's
//! read rather than running to completion before it starts. If either
//! `DotsMemory` or `FakeStore` read the wrong scope's bucket — the classic
//! failure mode for a server that pins state to a session instead of
//! threading it through every call — this test observes the other
//! scope's claim in the result and fails.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use dots_memory_mcp::store::{MemoryStore, SearchRow, StoreError, SubgraphRow};
use dots_memory_mcp::tools::{DotsMemory, RecallArgs, RememberArgs};
use rmcp::handler::server::wrapper::Parameters;
use uuid::Uuid;

/// One claim recorded under one scope.
type Claim = (String, String);

/// A `MemoryStore` whose state is a real map from scope to that scope's
/// claims, exercised concurrently rather than sequentially.
#[derive(Clone, Default)]
struct FakeStore {
    claims: Arc<Mutex<HashMap<String, Vec<Claim>>>>,
}

impl MemoryStore for FakeStore {
    async fn search(&self, scope: &str, _q: &str, _k: i32) -> Result<Vec<SearchRow>, StoreError> {
        // Scope "a" pauses mid-call so scope "b"'s write and read can land
        // while "a" is still in flight.
        if scope == "a" {
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        let claims = self.claims.lock().expect("lock poisoned");
        let rows = claims
            .get(scope)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(idx, (claim_key, body))| SearchRow {
                fact_id: i64::try_from(idx).expect("fixture row count fits in i64"),
                claim_key,
                body,
                rank: 1.0,
            })
            .collect();
        Ok(rows)
    }

    async fn ingest_fact(
        &self,
        scope: &str,
        claim_key: &str,
        body: &str,
        _source_kind: &str,
        _source_ref: &str,
        _unslop_token: &str,
        _session: Uuid,
    ) -> Result<i64, StoreError> {
        if scope == "a" {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let mut claims = self.claims.lock().expect("lock poisoned");
        let bucket = claims.entry(scope.to_string()).or_default();
        bucket.push((claim_key.to_string(), body.to_string()));
        Ok(i64::try_from(bucket.len()).expect("fixture row count fits in i64"))
    }

    async fn cite_fact(&self, _fact: i64, _session: Uuid) -> Result<(), StoreError> {
        Ok(())
    }

    async fn subgraph(
        &self,
        _scope: &str,
        _root: &str,
        _hops: i32,
    ) -> Result<Vec<SubgraphRow>, StoreError> {
        Ok(Vec::new())
    }

    async fn edges_to_mermaid(
        &self,
        _src: &[String],
        _verb: &[String],
        _dst: &[String],
    ) -> Result<String, StoreError> {
        Ok(String::new())
    }

    async fn note_session(
        &self,
        _session: Uuid,
        _scope: &str,
        _summary: &str,
        _files: &[String],
        _decisions: &str,
        _unfinished: &str,
        _unslop_token: &str,
    ) -> Result<(), StoreError> {
        Ok(())
    }
}

fn text_of(result: &rmcp::model::CallToolResult) -> String {
    result
        .content
        .iter()
        .filter_map(rmcp::model::ContentBlock::as_text)
        .map(|t| t.text.clone())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Two `remember` calls under different scopes, run concurrently with
/// `tokio::join!`, followed by two concurrent `recall` calls. Each
/// recall must report only the claim written under its own scope.
#[tokio::test]
async fn concurrent_scopes_never_cross_contaminate() {
    let server = DotsMemory::new(FakeStore::default());
    let session = Uuid::new_v4();

    let remember_a = server.remember(Parameters(RememberArgs {
        scope: "a".to_string(),
        claim_key: "key-a".to_string(),
        body: "scope a's fact".to_string(),
        source_kind: "test".to_string(),
        source_ref: "test-a".to_string(),
        unslop_token: "token-a".to_string(),
        session: session.to_string(),
    }));
    let remember_b = server.remember(Parameters(RememberArgs {
        scope: "b".to_string(),
        claim_key: "key-b".to_string(),
        body: "scope b's fact".to_string(),
        source_kind: "test".to_string(),
        source_ref: "test-b".to_string(),
        unslop_token: "token-b".to_string(),
        session: session.to_string(),
    }));
    let (remembered_a, remembered_b) = tokio::join!(remember_a, remember_b);
    assert!(remembered_a.is_ok(), "scope a's remember failed");
    assert!(remembered_b.is_ok(), "scope b's remember failed");

    let recall_a = server.recall(Parameters(RecallArgs {
        scope: "a".to_string(),
        query: "fact".to_string(),
        k: 10,
    }));
    let recall_b = server.recall(Parameters(RecallArgs {
        scope: "b".to_string(),
        query: "fact".to_string(),
        k: 10,
    }));
    let (recalled_a, recalled_b) = tokio::join!(recall_a, recall_b);

    let text_a = text_of(&recalled_a.expect("scope a's recall failed"));
    let text_b = text_of(&recalled_b.expect("scope b's recall failed"));

    assert!(
        text_a.contains("scope a's fact"),
        "scope a's recall is missing its own fact: {text_a}"
    );
    assert!(
        !text_a.contains("scope b's fact"),
        "scope a's recall leaked scope b's fact: {text_a}"
    );
    assert!(
        text_b.contains("scope b's fact"),
        "scope b's recall is missing its own fact: {text_b}"
    );
    assert!(
        !text_b.contains("scope a's fact"),
        "scope b's recall leaked scope a's fact: {text_b}"
    );
}
