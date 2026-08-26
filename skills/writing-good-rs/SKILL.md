---
name: writing-good-rs
description: Use when writing, reviewing or editing Rust, including choosing an error-handling crate, placing tests, adding logging, picking iterators over index loops, spawning threads or channels, reaching for an unstable feature, or benchmarking a Cargo crate.
---

# Writing good Rust

## Context

LLMs write Rust that compiles and still
reads like slop: no tests, `unwrap`
everywhere, logging added last. This is the
floor for anything under `rust/`.

## Rules

1. Follow the resources curated at
   https://bookshelf.rs.
2. Tests go in the crate's own `tests/`,
   e.g. `rust/<crate>/tests/`. Never an
   inline `#[cfg(test)] mod tests`.
3. Test real behaviour. A mock that only
   proves the mock works is not a test.
4. Prefer iterator chains to index loops.
   They drop bounds-check noise that blocks
   vectorization.
5. Reach for `channel`, `spawn` and scoped
   threads when they buy real parallelism,
   not by default.
6. Use `tracing` with `.without_time()`
   instead of `println!` for anything past a
   throwaway script.
7. Use `miette` for diagnostics, not
   `thiserror` or `anyhow`. When shelling
   out, surface the child's exit status and
   captured stderr through it, and parse
   JSON with `serde`.
8. Never `unwrap`, `expect` or `clone` your
   way past the compiler outside tests.
   Return a diagnostic, fix the lifetime.
9. Unstable features are fine only when
   `rust-toolchain.toml` targets nightly.
10. Benchmark before calling anything fast:
    `hyperfine` end to end for a binary,
    `criterion` or `divan` for a library.
11. Run pstack:unslop over commit messages,
    doc comments and README prose, never
    over the Rust source.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "`anyhow` is faster to write today" | And it throws away the span that would have found the bug tomorrow. |
| "Inline tests are conventional in Rust" | Cargo only compiles `tests/`. Convention does not move the directory. |
| "Iterators are guaranteed SIMD" | They are not. Autovectorization is best-effort LLVM. Claim the bounds checks, not the vectors. |
| "It is a small module, skip the logging" | Small modules fail in production too, and silently. |
| "This `unwrap` cannot fail here" | Then the diagnostic costs nothing and outlives your certainty. |
| "hyperfine does not fit this" | Then use `criterion` or `divan`. "Does not fit" is not a benchmark. |

## Target audience

Tiers calibrate the app shell, never the
rules above.

- **fucking don't care**: ships slop
  dashboards.
- **don't care**: fine if it is at least an
  Electron or Tauri app.
- **care**: prefers native apps.
- **really care**: prefers TUI apps.
- **Matus**: the last three, especially the
  cairo and pango stack `bemenu` uses.

## Post-run checklist

- [ ] Any inline `#[cfg(test)]` left?
- [ ] Do the tests assert real behaviour?
- [ ] Any `unwrap` outside `tests/`?
- [ ] Benchmarked, with a number to show?
