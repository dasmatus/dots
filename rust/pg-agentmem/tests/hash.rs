// Spliced into `mod tests` in src/lib.rs via `include!` -- see the comment
// there for why. Not a standalone Cargo integration test.

/// `norm_hash_v1` must not fall into `byteain`'s hex-escape reinterpretation:
/// `'\x616263'::bytea` decodes to three raw bytes, not the six-character
/// string `\x616263`, so hashing through a `text::bytea` cast would make
/// this text collide with `'abc'`. `norm_hash_v1` hashes the UTF-8 bytes of
/// the text directly and must tell the two apart.
#[pg_test]
fn test_norm_hash_v1_rejects_byteain_collision() {
    let hex_escaped: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1('\\x616263')")
        .unwrap()
        .unwrap();
    let plain: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1('abc')")
        .unwrap()
        .unwrap();
    assert_ne!(
        hex_escaped, plain,
        "norm_hash_v1 collided on the byteain escape case"
    );
}

/// The same input always hashes to the same digest.
#[pg_test]
fn test_norm_hash_v1_is_deterministic() {
    let first: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1('a stable claim')")
        .unwrap()
        .unwrap();
    let second: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1('a stable claim')")
        .unwrap()
        .unwrap();
    assert_eq!(first, second);
}

/// NFC-equivalent spellings (precomposed vs. combining-mark forms of the
/// same character) hash identically.
#[pg_test]
fn test_norm_hash_v1_normalises_nfc() {
    let precomposed: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1(U&'caf\\00E9')")
        .unwrap()
        .unwrap();
    let combining: Vec<u8> = Spi::get_one("SELECT agentmem.norm_hash_v1(U&'cafe\\0301')")
        .unwrap()
        .unwrap();
    assert_eq!(precomposed, combining);
}
