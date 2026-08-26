//! Error classification and the retry loop `remember` and `forget` use.
//!
//! Nothing here panics. A `StoreError` is either `Retry` — the write lost
//! a race against another writer and trying again is the correct response
//! — or `Fatal`, which becomes the `McpError` returned to the caller.

use std::future::Future;
use std::time::Duration;

use rand::Rng;
use rmcp::ErrorData as McpError;
use tokio_postgres::error::SqlState;

use crate::store::StoreError;

/// How many times a retryable write is attempted before giving up. One
/// initial attempt plus two retries.
const MAX_ATTEMPTS: u32 = 3;

/// The outcome of inspecting a `StoreError`.
pub enum Classification {
    /// A serialization conflict (`SQLSTATE 40001`, including
    /// `ingest_fact`'s `SUPERSEDE_LOST`). The caller lost a race with
    /// another writer and should try again.
    Retry,
    /// Anything else: a schema error, a connection failure, a rejected
    /// `unslop_token`. Retrying would not help.
    Fatal(McpError),
}

/// Classifies a `StoreError` as `Retry` or `Fatal`.
#[must_use]
pub fn classify_error(err: &StoreError) -> Classification {
    if let StoreError::Db(db_err) = err {
        if db_err.code() == Some(&SqlState::T_R_SERIALIZATION_FAILURE) {
            return Classification::Retry;
        }
    }
    Classification::Fatal(McpError::internal_error(err.to_string(), None))
}

/// Runs `attempt`, retrying up to `MAX_ATTEMPTS` times while the failure
/// classifies as `Retry`, with jittered backoff between tries.
///
/// `attempt` is called fresh each time rather than passed a resumable
/// future, so every retry is a brand new call into the store with no
/// state carried over from the failed one.
///
/// # Errors
/// Returns the `Fatal` classification of the last attempt's error as an
/// `McpError` once `attempt` has been tried `MAX_ATTEMPTS` times and
/// every failure classified as `Retry`, or immediately on the first
/// non-retryable failure.
pub async fn retry_on_conflict<F, Fut, T>(mut attempt: F) -> Result<T, McpError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, StoreError>>,
{
    for try_number in 1..=MAX_ATTEMPTS {
        match attempt().await {
            Ok(value) => return Ok(value),
            Err(err) => match classify_error(&err) {
                Classification::Retry if try_number < MAX_ATTEMPTS => {
                    let jitter_ms = rand::rng().random_range(10..50) * try_number;
                    tokio::time::sleep(Duration::from_millis(u64::from(jitter_ms))).await;
                }
                Classification::Retry => {
                    return Err(McpError::internal_error(
                        format!("gave up after {MAX_ATTEMPTS} attempts: {err}"),
                        None,
                    ));
                }
                Classification::Fatal(mcp_err) => return Err(mcp_err),
            },
        }
    }
    unreachable!("loop always returns by MAX_ATTEMPTS")
}
