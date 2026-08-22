---
name: c-compiler-preference
description: Use when writing, patching, or compiling C or C++ code, before choosing a compiler (gcc vs clang), setting CFLAGS/CXXFLAGS or other build flags, writing a patch to an existing C codebase, or running any build (make, autoreconf/configure, cmake, meson) that produces a C/C++ binary or library.
---

# C/C++ compiler preference

## Context

Plain, unhardened C is not an acceptable default. "The project already uses
gcc/plain C89" is not a reason to skip these rules. It is the reason to
apply them.

## Rules

### 1. Compiler: Clang, never GCC

Always build with `clang`/`clang++`, even if the project's `configure.ac`,
`CMakeLists.txt`, or CI defaults to `gcc`. Override the detected compiler
explicitly (e.g. `CC=clang CXX=clang++ ./configure`, `-DCMAKE_C_COMPILER=clang`).
Clang shares LLVM's backend with `rustc` and has the better tooling ecosystem
(sanitizers, `clang-tidy`, `clangd`, LTO).

### 2. Hardening: Control-Flow Integrity + ThinLTO

Always compile and link with:

```
-fsanitize=cfi -flto=thin -fvisibility=hidden -fuse-ld=lld
```

CFI requires LTO and hidden visibility to work, hence all three flags travel
together; `-fuse-ld=lld` picks the LLVM linker. ThinLTO needs an LTO-capable
linker, and lld works out of the box (gold-plugin and ld64
also qualify). The LTO flags must reach the *link* step too, so with autotools
put them in `LDFLAGS` as well:

```
CC=clang CXX=clang++ \
CFLAGS="-fsanitize=cfi -flto=thin -fvisibility=hidden" \
LDFLAGS="-flto=thin -fuse-ld=lld" ./configure
```

See:

- https://clang.llvm.org/docs/ControlFlowIntegrity.html
- https://clang.llvm.org/docs/ThinLTO.html

### 3. Language: Rust > C++ > C

Prefer Rust. If the task is a patch to an existing C program and rewriting it
in Rust is not viable, write the patch in the latest usable C++ standard
instead of matching the surrounding C. C++ avoids C's header hell, and its
patterns sit closer to Rust than C does. Do not just assume the latest
standard: at use time, web-search https://en.cppreference.com/w/cpp/compiler_support
to check which C++ standard the toolchain in play actually supports, then
target that one explicitly (e.g. `-std=c++2c`, `-std=c++23`). Landing C++ in
a C-only autotools project takes three small moves: `AC_PROG_CXX` in
`configure.ac`, a `.cpp` in `_SOURCES` (automake then links with `CXXLD`),
and `extern "C"` on symbols exported through the public header so the C ABI
survives.

### 4. Verification: sanitizers are mandatory, not optional

Then do a second, separate build with `-fsanitize=address,undefined`
replacing (not stacked on) the rule 2 flags, and run the test suite (or a
smoke driver if no suite exists) under it.

Fix every leak, use-after-free, overflow, and piece of undefined behavior
that ASan/UBSan report before handing the patch back. A clean `make check`
or one manual invocation without sanitizers is not evidence of safety.

## Rationalizations to reject

| Excuse | Why it doesn't hold |
|---|---|
| "gcc is the project's default compiler" | Override `CC`/`CXX` explicitly; the project default does not override this skill. |
| "Matching upstream style means writing plain C" | Style match stops at syntax conventions; the language and toolchain choice (rule 3) still applies to patches you author. |
| "Sanitizers are overkill for a small patch" | Small patches are exactly where a single missed bounds check goes unnoticed. Run ASan/UBSan regardless of patch size. |
| "autoconf/cmake already detects a working compiler" | Detection picks whatever's on `PATH`, usually gcc. Set `CC=clang CXX=clang++` (or the CMake/meson equivalent) yourself. |
| "The project doesn't already build with -Wall/-fsanitize, so adding flags isn't my call" | Hardening and sanitizer flags in rules 2 and 4 are non-negotiable regardless of the project's existing `CFLAGS`. |
| "`make check` passed and nobody asked for sanitizers" | That was never a memory-safety check. Rule 4 makes an ASan/UBSan run the default expectation for any C/C++ work, requested or not. |
| "The build system is C-only / adding C++ breaks the ABI" | `AC_PROG_CXX` plus `extern "C"` on the exported symbols is a 3-line fix, not an exemption. |
