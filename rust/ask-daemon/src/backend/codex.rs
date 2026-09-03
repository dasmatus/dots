//! The codex stub, which exists to prove the trait fits a backend nobody
//! has written yet.
//!
//! Section 3 of the spec gives codex no row in the mapping table and says
//! why: the binary is not installed on this machine, nothing was observed,
//! and a mapping written from documentation rather than from a capture would
//! be a guess dressed as a record. So this reports `unconfigured` and starts
//! nothing.
//!
//! It is not dead weight. It is the shape check on
//! [`crate::backend::Backend`]: a backend that has no process, no
//! credential, no transport and no decoder still satisfies the trait in
//! twenty lines, and the day somebody has a codex to record against, the
//! only file that has to change is this one.
//!
//! Filling it in means recording its protocol the way section 1 recorded the
//! `claude` one, putting the capture under `tests/fixtures/`, and writing
//! the decoder against that. Not from the docs.

use crate::backend::{unavailable, Backend, BackendContext, BackendHandle, CODEX};
use crate::proto::BackendInfo;
use crate::secrets::SecretStore;

/// The codex CLI, which this build cannot drive.
pub struct CodexBackend;

impl Backend for CodexBackend {
    fn id(&self) -> &'static str {
        CODEX
    }

    fn info(&self, _secrets: &SecretStore) -> BackendInfo {
        unavailable(
            CODEX,
            "Codex",
            "codex has no adapter yet: its protocol was never recorded, and one written from documentation rather than a capture would be a guess".to_owned(),
        )
    }

    fn start(&self, _ctx: BackendContext) -> Result<BackendHandle, String> {
        Err("codex has no adapter yet".to_owned())
    }
}
