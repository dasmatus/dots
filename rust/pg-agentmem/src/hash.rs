//! Content-addressing: SHA-256 over Unicode-NFC-normalised text.
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

/// Normalise `input` to Unicode NFC, then return its SHA-256 digest. Backs
/// `agentmem.norm_hash_v1` (see `lib.rs`).
///
/// This goes straight from `&str` to UTF-8 bytes to the hasher, and never
/// through a `text::bytea` cast. That cast runs through `PostgreSQL`'s
/// `byteain`, which reinterprets a leading `\x` as a hex escape, so
/// `'\x616263'::bytea` and `'abc'::bytea` collide even though the two texts
/// are unrelated. A content address built on that cast would silently merge
/// distinct facts.
pub fn hash_bytes(input: &str) -> Vec<u8> {
    let normalised: String = input.nfc().collect();
    let mut hasher = Sha256::new();
    hasher.update(normalised.as_bytes());
    hasher.finalize().to_vec()
}
