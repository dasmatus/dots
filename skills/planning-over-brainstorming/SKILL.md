---
name: planning-over-brainstorming
description: Use when a feature is about to be built, added or modified and the next step is invoking the brainstorming skill straight from normal mode, or when plan mode is being skipped on the grounds that it is only for big tasks.
---

# Planning over brainstorming

## Context

Plan mode edits no files, so exploring
intent there is free and reversible.
Brainstorming produces requirements, which
is exactly what a plan takes as input.

## Rules

1. When creative work starts, enter plan
   mode before anything else.
2. Invoke `superpowers:brainstorming` inside
   plan mode, never from normal mode.
3. Write the plan only once brainstorming
   has produced requirements.
4. A prior instruction to brainstorm first
   does not override this. Plan mode houses
   brainstorming, it does not skip it.
5. Any build, add or modify request
   qualifies, whatever its size.
6. Read files, search and run read-only
   commands in plan mode. Use them to ground
   the plan in what is actually there.
7. Edit nothing until the plan is approved.
   That freedom is the whole point of the
   mode.
8. Feed the requirements into the plan
   rather than restating them beside it.
9. Get approval before leaving plan mode.
10. Where the harness exposes no plan mode,
    state the plan in a message and get
    approval before the first edit.
11. A request to move fast is not a request
    to skip approval.
12. Once the plan exists, brainstorming-addon
    governs its quality.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "Brainstorming must run before anything, plan mode included" | Entering plan mode first skips nothing. The mode is where brainstorming belongs. |
| "Plan mode is only for big tasks" | Any build, add or modify request qualifies, regardless of size. |
| "The user said to just build it" | A request for speed is not a request to skip approval. Plan mode is where speed is safe. |
| "I already know the requirements" | Then brainstorming costs one exchange and confirms it. |
| "It is a one-line change" | One-line changes are where unstated assumptions hide best. |

## Target audience

- **fucking don't care**: starts editing on
  the first message.
- **don't care**: brainstorms, then edits
  without a plan.
- **care**: enters plan mode first.
- **really care**: brainstorms inside it and
  waits for approval.
- **Matus**: the last two.

## Post-run checklist

- [ ] Plan mode entered before brainstorming?
- [ ] Requirements produced before the plan?
- [ ] Zero edits made before approval?
- [ ] Approval actually given, not assumed?
