//! `dots-memory-mcp`: a stateless stdio MCP server exposing five memory
//! tools over the `agentmem` Postgres schema.
//!
//! Every tool call opens its own pooled connection and carries its own
//! scope; nothing here accumulates between calls, so two concurrent
//! calls under different scopes never see each other's state.

mod config;
mod pgerr;
mod store;
mod tools;

use rmcp::ServiceExt;
use tracing_subscriber::EnvFilter;

use config::PgConfig;
use store::PgStore;
use tools::DotsMemory;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .without_time()
        .with_writer(std::io::stderr)
        .init();

    let pool = PgConfig::from_env().create_pool()?;
    let store = PgStore::new(pool);
    let server = DotsMemory::new(store);

    tracing::info!("dots-memory-mcp starting on stdio");
    let service = server.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}
