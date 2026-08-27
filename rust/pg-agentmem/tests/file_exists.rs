// Spliced into `mod tests` in src/lib.rs via `include!` -- see the comment
// there for why. Not a standalone Cargo integration test.

/// A path that genuinely exists on the machine running the test (the
/// extension's own control file, guaranteed present wherever this crate
/// builds) must read back as existing.
#[pg_test]
fn test_file_exists_v1_true_for_real_path() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let control = format!("{manifest_dir}/pg_agentmem.control");
    let exists: bool = Spi::get_one(&format!("SELECT agentmem.file_exists_v1('{control}')"))
        .unwrap()
        .unwrap();
    assert!(exists, "expected {control} to exist");
}

/// A path built from a fresh random component cannot exist, so this must
/// come back false rather than erroring.
#[pg_test]
fn test_file_exists_v1_false_for_missing_path() {
    let missing: bool = Spi::get_one(
        "SELECT agentmem.file_exists_v1('/nonexistent/agentmem-test-path/does-not-exist')",
    )
    .unwrap()
    .unwrap();
    assert!(!missing, "expected a made-up path to not exist");
}
