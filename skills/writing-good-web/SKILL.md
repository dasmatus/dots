---
name: writing-good-web
description: Use when building or reviewing anything that runs in a browser, choosing a web stack, deciding between WebAssembly and script, writing frontend JavaScript or TypeScript, wiring wasm-bindgen or wasm-pack, or judging whether browser-side work is fast enough.
---

# Writing good web

## Context

The browser is the one place where reaching
for the ecosystem default puts the logic in
the weakest language available. The order
below moves it back.

## Rules

1. The order is Rust compiled to wasm32,
   then TypeScript, then JavaScript. Never
   reach past a rung.
2. Compute-heavy or stateful logic is Rust
   on wasm32, built with `wasm-bindgen`,
   `wasm-pack` or `trunk`.
3. Script code stays thin glue for the DOM
   and platform APIs. Logic that could live
   in Rust does not belong there.
4. When script is unavoidable it is
   TypeScript. Never plain JavaScript.
5. Route the Rust side to writing-good-rs
   and any `.ts` or `.tsx` to
   pstack:typescript-best-practices.
6. Keep boundary crossings coarse. A
   per-item call into wasm spends more on
   marshalling than the work it saves.
7. Pass a defined structure across that
   boundary, not an ad-hoc JSON string
   assembled at the call site.
8. Measure the bundle before shipping it. A
   wasm blob nobody sized is a regression
   waiting to be noticed by a user.
9. Profile before accepting that any row
   count is fine in script. A number with no
   benchmark behind it is a guess.
10. Verify in a real browser. A build that
    succeeded is not a page that works.
11. Use semantic elements and keep every
    control reachable by keyboard.
12. Run pstack:unslop over user-facing copy,
    never over the source.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "A few hundred thousand rows is fine in JS" | There is no benchmark behind that number. Profile first. |
| "I will add wasm once profiling shows a bottleneck" | It never gets revisited. The order puts heavy logic in Rust up front. |
| "wasm is overkill for a small page" | Overkill is a size argument, and size does not move the order. |
| "The web ecosystem is JavaScript anyway" | That is the glue layer. `wasm-bindgen` keeps the logic out of it. |
| "TypeScript slows shipping" | Untyped script fails like untested Rust, only later and in someone's browser. |
| "It renders on my machine" | One browser at one width is not verification. |

## Target audience

- **fucking don't care**: ships a bundle of
  untyped script.
- **don't care**: TypeScript, logic still in
  the browser.
- **care**: heavy work moved to wasm.
- **really care**: wasm by default, script
  reduced to glue.
- **Matus**: the last two.

## Post-run checklist

- [ ] Heavy logic in Rust, not in script?
- [ ] Any plain `.js` left?
- [ ] Boundary crossings coarse, not per row?
- [ ] Bundle size measured?
- [ ] Opened in a real browser?
