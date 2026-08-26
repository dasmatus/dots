//! Environment-derived connection settings for the `agentmem_mcp` role.
//!
//! `tokio_postgres` does not read the standard `PG*` environment variables
//! the way `libpq`-linked clients do, so every value the server needs is
//! read here explicitly rather than left to driver defaults.

use deadpool_postgres::{Config as PoolConfig, Runtime};

/// The role every connection this server opens authenticates as.
///
/// Fixed rather than configurable: plan 2 grants `EXECUTE` on the five
/// `agentmem` functions to exactly this role and nothing else, so a
/// different role would either fail to connect (no matching `pg_ident`
/// entry) or, worse, succeed with different privileges than the ones this
/// server was designed to run under.
const PG_USER: &str = "agentmem_mcp";

/// Connection settings assembled from the process environment.
///
/// Holds no scope, no session, and no per-call state: every field here is
/// fixed for the lifetime of the process, set once at startup from the
/// environment and never mutated afterward.
#[derive(Debug, Clone)]
pub struct PgConfig {
    host: String,
    dbname: String,
    options: Option<String>,
}

impl PgConfig {
    /// Reads `PGHOST`, `PGDATABASE`, and `PGOPTIONS` from the environment.
    ///
    /// `PGHOST` defaults to `/run/postgresql`, the standard Debian/NixOS
    /// unix-socket directory, so peer auth over the socket works with no
    /// environment set at all. `PGDATABASE` defaults to `matus`: plan 2's
    /// `ensureDBOwnership` forces the database name to equal the owning
    /// role, and `matus` is that role, with `agentmem` living inside it as
    /// a schema rather than a separate database. `PGOPTIONS` has no
    /// default; when unset, `search_path` is whatever the role's default
    /// is, which plan 2 already sets to include `agentmem`.
    #[must_use]
    pub fn from_env() -> Self {
        let host =
            std::env::var("PGHOST").unwrap_or_else(|_| "/run/postgresql".to_string());
        let dbname =
            std::env::var("PGDATABASE").unwrap_or_else(|_| "matus".to_string());
        let options = std::env::var("PGOPTIONS").ok();
        Self { host, dbname, options }
    }

    /// Builds a `deadpool_postgres::Pool` from this configuration.
    ///
    /// # Errors
    /// Returns whatever `deadpool_postgres::CreatePoolError` the pool
    /// builder produces, e.g. an invalid `options` string.
    pub fn create_pool(&self) -> Result<deadpool_postgres::Pool, deadpool_postgres::CreatePoolError> {
        let mut cfg = PoolConfig::new();
        cfg.host = Some(self.host.clone());
        cfg.dbname = Some(self.dbname.clone());
        cfg.user = Some(PG_USER.to_string());
        cfg.options = self.options.clone();
        cfg.create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
    }
}
