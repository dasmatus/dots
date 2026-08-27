---
name: subagent-driven-by-default
description: Use when an implementation plan has just been approved, when leaving plan mode for execution, when the first task from an approved plan is about to start, or when reaching for Edit or Write on a file the plan owns. Does not fire for a one-off question or a quick fix with no plan behind it.
---

# Subagent-driven by default

## Context

A plan gets approved and the easy move is
editing its files right here, which drops
isolation and review. This skill makes
subagent-driven-development the default.

## Rules

1. At each trigger above, invoke
   superpowers:subagent-driven-development.
   It is the default, not an option.
2. Editing the plan's files here is the
   exception. Ledger the reason first.
3. Dispatch a fresh subagent per task;
   none inherits this session's history.
4. Hand off work as file paths; pasted
   text stays in context all session.
5. Batch same-shape small edits across
   files into one dispatch, not one
   agent per task.
6. A dispatched agent never dispatches
   its own reviewer; review comes from
   this session, after the report lands.
7. Review every task before moving on;
   run one whole-branch review at the end.
8. Keep a ledger file; todos do not
   survive compaction. After one, trust
   the ledger and `git log` over memory.
9. Rule on what the plan leaves open
   instead of asking; ledger it and move on.
10. Stop only for four things: an
    irreversible or destructive step, a
    security-sensitive action, a side
    effect outside the worktree, or a plan
    so broken every path is a guess.
11. Execute in an isolated worktree, never
    on main without consent, and never run
    two implementers on it at once.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The plan is small, I'll just edit it here" | Size was never the trigger; an approved plan is. |
| "Todos already track where I am" | Todos do not survive compaction. The ledger does. |
| "Two implementers finish twice as fast" | They collide on the one worktree. The next dispatch waits for the last commit. |
| "I'll paste the diff so it's visible" | Pasted text lives in context for the rest of the session. Hand over a path instead. |
| "Asking is safer than ruling" | A running plan does not wait. Rule on it, ledger the ruling, keep going. |
| "This edit counts as the exception" | The exception is the plan's own files for a recorded reason, not convenience. No ledger line, no exception. |

## Target audience

- **fucking don't care**: edits the
  plan's files here and calls it done.
- **don't care**: dispatches once, then
  finishes the rest here anyway.
- **care**: dispatches every task, no ledger.
- **really care**: dispatches, ledgers
  every ruling, reviews every task.
- **Matus**: the last two, and reads the
  ledger before trusting memory.

## Post-run checklist

- [ ] subagent-driven-development invoked
      before task one?
- [ ] Every in-session edit ledgered?
- [ ] One fresh subagent per task, one
      implementer per worktree?
- [ ] A review per task, plus one final?
- [ ] Ledger names every ruling made?
