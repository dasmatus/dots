---
name: writing-good-rs
description: Use when writing, reviewing, or editing Rust code: choosing an error-handling crate, writing or placing tests, adding logging, using iterators vs index loops, spawning threads or channels, considering unstable features, or benchmarking a Cargo crate.
---

# Writing good Rust

## Context

LLMs write bugs, shit-quality code (see `rust/beamenu`), broken UI, poor SecOps, no tests, and no advice on where code should even live. This skill exists to stop that, especially when Fable is running on xhigh with Ultracode.

## Rules

1. Strictly follow the resources curated at https://bookshelf.rs.
2. Write tests that exercise real functionality, never a mock that only proves the mock works. Tests live in the crate's own `tests/` directory (e.g. `rust/<crate>/tests/`; cargo never compiles tests dropped anywhere else). Never write inline `#[cfg(test)] mod tests` in source files; they pollute the file. This applies even under time pressure. Do not defer proper tests "to later."
3. Prefer iterator chains over hand-rolled index loops. This is not because std iterators are guaranteed SIMD or "always 100% faster". They aren't: autovectorization is a best-effort LLVM optimization, not a language guarantee. Iterators help because they drop bounds-check noise that blocks vectorization and read cleaner. State this honestly, don't oversell it.
4. Use `channel`s, `spawn`s, and scoped threads responsibly for concurrency; reach for them when they buy real parallelism, not by default.
5. Prefer `tracing` with `.without_time()` over `println!` for anything beyond a throwaway script, including "small" modules. Don't skip logging just because nobody asked.
6. Prefer `miette` over `thiserror`/`anyhow` for error diagnostics, including under deadline pressure, where the instinct is to reach for `anyhow` and `.context()` everywhere and clean it up later. Don't. When shelling out, surface the child's non-zero exit status and captured stderr through the miette diagnostic instead of swallowing them; parse JSON with `serde`/`serde_json`.
7. Less hand-written code is better. Lean on the ecosystem for security and performance instead of reinventing it.
8. Unstable features are allowed when they clearly cut boilerplate, but this requires a nightly toolchain; only use them when the project's toolchain (e.g. `rust-toolchain.toml`) already targets nightly.
9. Invoke the pstack:unslop skill over the prose deliverables: commit messages, doc comments, README. Not the Rust source itself.

## Target audience

Read context memory to determine which of these the user is. The tiers calibrate UI/app-shell choices only. They never relax the Rules or the checklist above; there is no tier where code slop is acceptable:

- **fucking don't care**: ships slop dashboards, doesn't mind if the code reads like slop.
- **don't care**: fine as long as it's at least an Electron/Tauri app.
- **care**: prefers native apps.
- **really care**: prefers TUI apps.
- **Matus**: loves the last three, and especially the toolkit `bemenu` uses (cairo + pango).

## Post-test checklist

- [ ] Does the code look like slop?
- [ ] (if it's an app) Does the UI look sloppy?
- [ ] Is there excessive test abuse (tests that assert nothing real)?
- [ ] How fast is it, really? (binaries/CLIs: benchmark end-to-end with hyperfine; library code: an in-process harness like criterion or divan; "hyperfine doesn't fit" is not a pass)
