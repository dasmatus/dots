---
name: writing-good-cpp
description: Use when writing or patching C or C++ source, picking a container, walking a container, passing a buffer across a function boundary, declaring a struct or class, managing ownership or a C API allocation, or wiring a C++ file into a C-only build.
---

# Writing good C++

## Context

A `struct` any free function can reach into
has no owner for its invariant. C++ written
to match the surrounding C throws away the
guarantees the language could have given.

## Rules

1. When a C patch cannot become Rust, write
   C++ rather than match the C around it.
   RAII and iterators sit closer to Rust.
2. Default to `std::vector`, or `std::array`
   when the size is fixed at compile time.
   Never a hand-rolled `malloc`/`free`
   buffer or a raw `new[]`/`delete[]`.
3. Walk containers with range-for or an
   `<algorithm>`/`<ranges>` call, never
   `for (int i = 0; i < v.size(); ++i)`.
   ES.71 marks that form bad.
4. Pass `std::span` or `std::string_view`,
   never a raw pointer with a separate
   length or a `const char*` read to `\0`.
5. A type with an invariant is a `class`
   with private data reachable only through
   its members (C.2). `struct` stays passive.
6. Acquire a resource in the constructor,
   release it in the destructor.
7. Prefer the rule of zero, composing from
   members already RAII types. Rule of five
   only when a class owns a raw resource.
8. Own through `std::unique_ptr`, or
   `std::shared_ptr` when ownership is
   genuinely shared. No bare `new`/`delete`
   outside the owning class.
9. Memory a C API handed back (`strdup`,
   `getline`, `asprintf`) gets freed by a
   `unique_ptr` with a custom deleter, not a
   stray `free`.
10. Wiring C++ into a C autotools project
    takes `AC_PROG_CXX`, a `.cpp` in
    `_SOURCES`, and a guarded `extern "C"`
    block with default visibility.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The surrounding code uses `char*` everywhere" | Style matching stops at syntax. That `char*` is usually why the bug exists. |
| "A class is overkill for this" | An invariant with no owner is a bug waiting for a caller to break it. |
| "`malloc` is faster than `std::vector`" | Unmeasured. Profile before trading away bounds and lifetime safety. |
| "It is just one index loop" | One is enough for the off-by-one, and range-for is shorter to type. |
| "The build system is C-only" | A guarded `extern "C"` block is four lines, not an exemption. |

## Target audience

- **fucking don't care**: plain C, structs
  poked by free functions.
- **don't care**: compiled it as C++.
- **care**: reaches for `std::vector`.
- **really care**: containers and RAII by
  default, an owner for everything.
- **Matus**: the last two, and wants it to
  read like the Rust would.

## Post-run checklist

- [ ] Any `malloc`, array or `new[]` left?
- [ ] Any index or iterator loop left?
- [ ] Any pointer plus length at a boundary?
- [ ] Any invariant in a bare struct?
- [ ] Any owning pointer without a deleter?
