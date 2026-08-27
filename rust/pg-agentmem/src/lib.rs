//! `pg_agentmem`: content addressing, id slugification, and a strict-subset
//! Mermaid flowchart parser/renderer, exported as `IMMUTABLE` functions in
//! the `agentmem` schema. The extension defines no tables and grants no
//! privileges; the memory store built on top of it is a separate schema.
pgrx::pg_module_magic!();

mod fsutil;
mod hash;
mod mermaid;
mod render;

/// The `agentmem` schema and its four `IMMUTABLE` functions. `#[pg_schema]`
/// derives the schema name from this module's own identifier and emits its
/// `CREATE SCHEMA IF NOT EXISTS agentmem;` -- a function's `schema = "..."`
/// attribute is only accepted once a matching schema module exists, so
/// these wrappers live here rather than as free functions in `hash`,
/// `mermaid` and `render`. Each wrapper is a thin adapter over the pure
/// logic those modules hold, the part with anything to unit test.
#[pgrx::pg_schema]
mod agentmem {
    use pgrx::prelude::*;

    /// Normalise `input` to Unicode NFC, then return its SHA-256 digest.
    /// Never goes through a `text::bytea` cast -- see `hash::hash_bytes`.
    #[pg_extern(immutable)]
    fn norm_hash_v1(input: &str) -> Vec<u8> {
        crate::hash::hash_bytes(input)
    }

    /// Map arbitrary text to a Mermaid-safe identifier.
    #[pg_extern(immutable)]
    fn slug_v1(input: &str) -> String {
        crate::render::slug(input)
    }

    /// Parse a strict-subset Mermaid flowchart document into its edges.
    #[pg_extern(immutable)]
    fn mermaid_edges(
        doc: &str,
    ) -> TableIterator<
        'static,
        (
            name!(ord, i32),
            name!(src, String),
            name!(verb, String),
            name!(dst, String),
            name!(directed, bool),
        ),
    > {
        match crate::mermaid::parse(doc) {
            Ok(edges) => TableIterator::new(
                edges
                    .into_iter()
                    .map(|e| (e.ord, e.src, e.verb, e.dst, e.directed)),
            ),
            Err(message) => pgrx::error!("mermaid_edges: {message}"),
        }
    }

    /// Whether `path` exists on the local filesystem. Not `IMMUTABLE` --
    /// the filesystem is external state, and the whole point of this
    /// function is to notice when it has changed. Backs the staleness
    /// sweep's file-missing check (`agentmem._mark_stale`, migration
    /// 0004): a `remembered` fact whose `source_ref` names a file must not
    /// outlive that file.
    #[pg_extern(volatile)]
    fn file_exists_v1(path: &str) -> bool {
        crate::fsutil::path_exists(path)
    }

    /// Render parallel edge arrays back into a flowchart document.
    // pgrx's `text[]` binding hands the extern function an owned `Vec`
    // rather than a borrowed slice, so this can't take `&[String]` directly.
    #[allow(clippy::needless_pass_by_value)]
    #[pg_extern(immutable)]
    fn edges_to_mermaid(src: Vec<String>, verb: Vec<String>, dst: Vec<String>) -> String {
        crate::render::render(&src, &verb, &dst)
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
    include!("../tests/mermaid_edges.rs");
    include!("../tests/edges_to_mermaid.rs");
    include!("../tests/file_exists.rs");
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
