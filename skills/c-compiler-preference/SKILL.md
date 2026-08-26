---
name: c-compiler-preference
description: Use when choosing a compiler for C or C++, setting CFLAGS/CXXFLAGS or link flags, configuring autotools, cmake or meson, or running any build that produces a C/C++ binary or library. Covers the toolchain; writing-good-cpp covers the code itself.
---

# C/C++ toolchain

## Context

gcc has no `-fsanitize=cfi` to give you, and
a build that links is not a build anyone
checked. A project defaulting to gcc is the
reason to apply these rules, not to skip.

## Rules

1. Build with `clang` and `clang++`, even
   when `configure.ac` or CI defaults to
   gcc. Clang shares LLVM's backend with
   `rustc` and has the better sanitizers.
2. Override the default explicitly:
   `CC=clang CXX=clang++ ./configure`, or
   `-DCMAKE_C_COMPILER=clang` and its C++
   twin, in a fresh build directory.
3. Harden with `-fsanitize=cfi -flto=thin`,
   `-fvisibility=hidden` and `-fuse-ld=lld`
   on the compile and the link line both.
4. Set all three or none, and confirm `lld`
   is installed rather than assuming
   `-fuse-ld=lld` resolves. A plugin-enabled
   `ld` or `gold` also works.
5. A static library under autotools needs
   `AR=llvm-ar RANLIB=llvm-ranlib`, or the
   archiver strips the LTO bitcode before
   the link ever sees it.
6. Check the standard with feature-test
   macros (`__cpp_lib_span`), then name it
   as `-std=c++23`. Never assume the newest
   one is available.
7. Compile with `-Wall -Wextra -Werror`. A
   warning you scrolled past is a finding
   you did not fix.
8. Build a second time with
   `-fsanitize=address,undefined` and
   `-fno-sanitize-recover=all`.
9. Keep that build separate from rule 3, so
   a CFI trap cannot be misread as a
   sanitizer finding.
10. Run the suite under it and fix every
    leak, use-after-free, overflow and UB
    report before handing the patch back.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "gcc is the project's default" | Override `CC`/`CXX`. gcc has no `-fsanitize=cfi` to offer. |
| "Sanitizers are overkill for a small patch" | A missed bounds check fits in a small patch just fine. |
| "UBSan ran and exited clean" | UBSan recovers by default. Without `-fno-sanitize-recover=all` a clean exit proves nothing. |
| "I put every flag in one build" | CFI and ASan confuse each other's traps. Two builds. |
| "`-Werror` breaks the existing build" | Then the existing build has findings. That is the point. |

## Target audience

Tiers say how far short the build sits, not
where you may stop.

- **fucking don't care**: gcc, stock flags.
- **don't care**: clang, stock flags.
- **care**: hardening flags added.
- **really care**: two builds, suite green.
- **Matus**: the last two.

## Post-run checklist

- [ ] `clang++` set, cmake variables too?
- [ ] CFI, ThinLTO, visibility all three on?
- [ ] `llvm-ar`/`llvm-ranlib` for static libs?
- [ ] Standard checked, not assumed?
- [ ] Sanitizer build run, suite clean?
