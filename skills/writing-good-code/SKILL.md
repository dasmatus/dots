---
name: writing-good-code
description: Use when starting or reviewing any compiled or systems code task, before picking a language for new work, before touching an existing C or C++ codebase, before writing FFI bindings to a C library, or when a task spans more than one of Rust, C++ and C.
---

# Writing good code

## Context

This is the entry point for compiled and systems
work, and the per-language skills below carry the
actual rules. Its own job is picking the language
and routing.

## Rules

1. New code is Rust. Full stop.
2. Where Rust is not an option, the order is C++,
   then C. Never reach past a rung.
3. A patch to existing C follows writing-good-cpp
   for the code and c-compiler-preference for the
   build.
4. Binding to a C library keeps the boundary
   thin. Bindings and logic live on the Rust
   side.
5. Generate bindings with `bindgen`. Write
   `extern "C"` by hand only where bindgen cannot
   run, and pin the header version when you do.
6. Never add C glue a Rust wrapper could absorb
   instead.
7. Give every unsafe FFI call a safe Rust
   wrapper, and every `unsafe` block a SAFETY
   comment.
8. A C or C++ shim in a Rust binary shares one
   link step, so LTO and CFI become a whole-link
   call including `rustc`.
9. When `rustc` cannot join that LTO link, say so
   and still run the sanitizer build. Dropping
   CFI quietly is not the fallback.
10. A mixed task fires every skill below at once,
    each governing its own side.
11. Verify before claiming done: each side runs
    its own skill's checks, plus the repo's
    format and lint commands.

## Routing

| Work | Skill |
|---|---|
| Any Rust, web included | writing-good-rs |
| C or C++ source | writing-good-cpp |
| C or C++ builds and flags | c-compiler-preference |
| Anything targeting a browser | writing-good-web |
| Any `.ts` or `.tsx` | pstack:typescript-best-practices |

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "It is a tiny helper, plain C is fine" | Size does not move the language order. |
| "It is mostly C, so the C rules cover it" | A mixed task puts every relevant skill in force. |
| "FFI means writing the glue in C" | FFI means bindings, and those live in Rust. |
| "The wrapper is thin, skip the safe/unsafe split" | Thin still gets a wrapper and a SAFETY comment. |
| "I ran the checklist" | Narration is not evidence. Match the claim to real output. |

## Target audience

- **fucking don't care**: matches the file.
- **don't care**: picks what compiles.
- **care**: follows the order.
- **really care**: follows it and routes.
- **Matus**: the last two.

## Post-run checklist

- [ ] Language picked by the order?
- [ ] Every applicable skill above fired?
- [ ] Every `unsafe` block carrying SAFETY?
- [ ] Each side's own checks actually run?
