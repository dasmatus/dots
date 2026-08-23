---
name: writing-good-code
description: Use when starting or reviewing any compiled, systems, or web code task, before picking a language or stack for new work, before touching an existing C or C++ codebase, before writing FFI bindings to a C library, or before choosing a web stack (web app, frontend, JavaScript, TypeScript, WebAssembly, WASM). Triggers on choosing between Rust, C++, and C, and on tasks that touch more than one of them.
---

# Writing good code

## Context

Entry point for compiled, systems, and web code in this repo; writing-good-rs, c-compiler-preference, and pstack:typescript-best-practices carry the per-language rules.

## Language choice

Strict order: Rust, then C++, then C.

- New code is Rust, full stop.
- A patch to existing C code follows c-compiler-preference.
- Binding to an existing C library keeps the boundary thin: bindings and logic live on the Rust side, bindgen by default, hand-rolled `extern "C"` only where bindgen cannot run and with the header version pinned, never new C glue a wrapper could absorb. Unsafe FFI gets a safe Rust wrapper; every unsafe block carries a SAFETY comment.
- A C/C++ shim linked into a Rust binary shares one link step. LTO/CFI becomes a whole-link decision, rustc included (e.g. `-Clinker-plugin-lto`). When rustc cannot join the LTO link, say so explicitly and still run the mandatory ASan/UBSan build; silently dropping CFI is not the fallback, and half a CFI configuration never ships.

## Web

Strict order: Rust compiled to WebAssembly, then TypeScript, then JavaScript.

- Compute-heavy or stateful logic is Rust compiled to wasm32 (wasm-bindgen, wasm-pack, or trunk); script code stays thin glue for DOM and platform APIs.
- When script code is unavoidable, it is TypeScript, never plain JavaScript.

## Routing

**REQUIRED SUB-SKILL:** writing-good-rs for any Rust, web included.

**REQUIRED SUB-SKILL:** c-compiler-preference for any C or C++.

**REQUIRED SUB-SKILL:** pstack:typescript-best-practices for any .ts or .tsx.

Mixed tasks fire every applicable sub-skill at once, each governing its own side; none get restated here.

## Shared gates

Verification is mandatory before claiming done: each side runs its own sub-skill's verification, plus the repo's formatting and conformance commands.

## Rationalizations to reject

| Excuse | Why it doesn't hold |
|---|---|
| "It's a tiny helper, plain C is fine" | Size doesn't change the language choice. |
| "It's mostly C already, so C rules cover it" | Mixed tasks put every relevant sub-skill in force. |
| "FFI means writing the glue in C" | FFI means bindings, not glue; those live in Rust. |
| "The wrapper is thin, skip the safe/unsafe split" | Thin still gets a wrapper and a SAFETY comment. |
| "A few hundred thousand rows is fine in JS" | No benchmark behind that number; profile first. |
| "I'll add WASM once profiling shows a bottleneck" | Rarely revisited; the order puts heavy logic in Rust/WASM up front. |
| "I ran the checklist" / "no speculative deps" | Narration isn't evidence; match claims to output and imports. |
| "WASM is overkill for a small page" | Overkill is a size argument; logic still goes to Rust/WASM. |
| "The web ecosystem is JavaScript anyway" | That's the glue surface; wasm-bindgen keeps logic out of it. |
| "TypeScript slows shipping" | Untyped script fails like untested Rust, just later, in the browser. |
| "Full lint/smoke suite is too slow for a helper" | Helper size doesn't shrink the gate; a build that compiles isn't a build that's verified. |
