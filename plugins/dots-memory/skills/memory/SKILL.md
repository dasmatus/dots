---
name: memory
description: Use when a session opens and recalled facts appear in context, before calling remember on anything durable, when retracting or correcting a stored claim, or when a human wants to see how scoped facts connect.
---

# Dots memory

## Context

Recall happens for you, unasked, at
session start. Writing does not: every
store is a visible tool call the model
chooses, never a background harvest.

## Rules

1. Read the digest at session start as
   recalled memory, not new information.
2. Never call `remember` on a fact the
   digest just served this session.
3. Never call `remember` on a fact
   `search` already returns as live.
4. Call `remember` only for what the
   checkout cannot answer by itself.
5. Never call `remember` for anything
   `rg`, `git log` or `nix eval` answer.
6. Skip `remember` for content fetched
   from outside the session entirely.
7. Use `forget` to retract a claim, not a
   second `remember` beside the old one.
8. Call `recall` mid-session only when the
   digest's cap likely dropped something
   relevant. Do not re-query on a whim.
9. Call `graph` for a human who wants to
   see connections, one or two hops from
   a named node. Never render it whole.
10. Treat the `Stop` nudge as a question,
    not an instruction: answer only if
    something was actually learned.
11. Scope every call to the current
    project. Never write across scopes.
12. If Postgres is down, the digest comes
    back empty and every tool call fails
    clean. Keep working regardless.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "Restating it reinforces it" | That is the mem0 loop: a fact recalled, re-extracted, and stored again. |
| "It might be useful someday" | Unused stores rot; one audit found 26 of 45 files never read once. |
| "The user just told me, better save it" | Only if code and `rg` cannot already answer it later. |
| "The nudge means I must write something" | It is a question. An empty session answers it honestly. |

## Target audience

- **fucking don't care**: calls `remember`
  on every reply.
- **don't care**: remembers preferences
  nobody asked to persist.
- **care**: checks `rg` and `git log`
  before deciding it is new.
- **really care**: lets the `Stop` nudge
  go unanswered on purpose.
- **Matus**: the last two, and reads
  `search` results before trusting recall.

## Post-run checklist

- [ ] Did `remember` skip anything the
      digest or `search` already covers?
- [ ] Was `graph` scoped to a real node,
      never the whole store?
- [ ] Did a retraction use `forget`, not a
      second `remember`?
- [ ] Was the `Stop` nudge answered only
      when something was actually learned?
