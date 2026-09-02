---
name: model-hierarchy
description: Use when delegating, orchestrating or spawning subagents for research, web search, writing, documentation, code or diff review, or architecture and implementation planning, including when choosing which tier to assign a subtask, how many agents to spawn, or whether a CLAUDE.md routing rule applies.
---

# Model hierarchy

## Context

Top-tier usage is the scarce resource here,
and every subtask handled in session spends
it. One unverified agent costs more to redo
than a verifier would have cost to run.

## Rules

1. Delegate every subtask that can be
   delegated. Orchestration is the one role
   that never leaves this session.
2. Assign the smallest tier capable of the
   task type. Capability is not the deciding
   factor, task type is.
3. Mechanical work goes to the smallest tier:
   lookups, boilerplate, formatting,
   straightforward diff scanning.
4. Writing, documentation and web research go
   to the mid tier.
5. Code review, diff review and PR review go
   to the large tier, never the mid one.
6. Architecture and implementation planning go
   to the top tier.
7. CLAUDE.md names which model fills each
   tier. Read the mapping there rather than
   guessing, and follow it when it conflicts
   with anything here.
8. Sub-delegation moves one rung down from the
   assigned tier, never two.
9. Every delegated task spawns a pair: a doer
   and an independent verifier.
10. Pair even when the task cannot be split.
    Pairing is a floor, not a reward for size.
11. Run the verifier at the doer's tier. One
    rung down only for a purely mechanical
    check.
12. Fan-out is a separate decision stacked on
    top of the pair, never a substitute for
    it.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The top tier would just do it better" | It would, and that is the budget this skill protects. Match the tier to the task type. |
| "A verifier doubles the cost" | It costs one rung. Redoing work a single unchecked agent botched costs the whole task, at the top tier. |
| "CLAUDE.md already covers the routing" | It names the models. It does not excuse skipping the pair or routing review to the wrong tier. |
| "One agent per subtask unless it splits" | Splitting and pairing are different questions. Every subtask gets a verifier regardless. |
| "Diff review is basically reading" | Review is its own task type and it routes to the large tier. |
| "This task is too small to delegate" | Then it is small enough for the smallest tier. |

## Target audience

- **fucking don't care**: does every subtask
  in the orchestrating session.
- **don't care**: delegates, always to the
  biggest tier available.
- **care**: matches tier to task type.
- **really care**: matches tiers and pairs
  every doer with a verifier.
- **Matus**: the last two, and watches the
  weekly limit.

## Post-run checklist

- [ ] Every delegable subtask delegated?
- [ ] Tier matched to task type, not to
      difficulty?
- [ ] Review routed to the large tier?
- [ ] Every doer paired with a verifier?
- [ ] Orchestration kept in session?
