//! `dots-memory-derive`: mechanically reads this checkout's own structure
//! and prints it as `origin = 'derived'` Mermaid edges. Takes the repo
//! root as `argv[1]`, defaulting to `.`. Never calls a model; anything
//! needing judgement belongs to the `remembered` write path instead.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let repo_root = std::env::args()
        .nth(1)
        .map_or_else(|| PathBuf::from("."), PathBuf::from);

    match dots_memory_derive::emit(&repo_root) {
        Ok(doc) => {
            print!("{doc}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("dots-memory-derive: {message}");
            ExitCode::FAILURE
        }
    }
}
