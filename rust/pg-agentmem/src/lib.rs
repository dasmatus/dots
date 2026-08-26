//! `pg_agentmem`: content addressing for the `agentmem` memory store,
//! exported as an `IMMUTABLE` function. The extension defines no tables and
//! grants no privileges; the memory store built on top of it is a separate
//! schema.
pgrx::pg_module_magic!();

mod hash;

/// The `agentmem` schema and its `IMMUTABLE` functions. `#[pg_schema]`
/// derives the schema name from this module's own identifier and emits its
/// `CREATE SCHEMA IF NOT EXISTS agentmem;` -- a function's `schema = "..."`
/// attribute is only accepted once a matching schema module exists, so this
/// wrapper lives here rather than as a free function in `hash`. It is a
/// thin adapter over the pure logic that module holds, the part with
/// anything to unit test.
#[pgrx::pg_schema]
mod agentmem {
    use pgrx::prelude::*;

    /// Normalise `input` to Unicode NFC, then return its SHA-256 digest.
    /// Never goes through a `text::bytea` cast -- see `hash::hash_bytes`.
    #[pg_extern(immutable)]
    fn norm_hash_v1(input: &str) -> Vec<u8> {
        crate::hash::hash_bytes(input)
    }
}

// A pgrx `#[pg_test]` function must be compiled into this crate's cdylib to
// become a callable SQL entity under `pg_module_magic!`'s extension, so the
// actual test bodies are spliced in here with `include!` rather than being
// left as ordinary Cargo integration tests (which build the crate's `.rlib`
// alone and never touch the running extension). The test source still lives
// under `tests/`, not inline in this file; `autotests = false` in
// Cargo.toml stops Cargo from also building those files as separate,
// non-functional test binaries.
#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use pgrx::prelude::*;

    include!("../tests/hash.rs");
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
