---
name: brainstorming-addon
description: Use when a plan is being drafted, revised or about to be shown inside plan mode, meaning right after the user's first answer, again while planning, and once more before the final plan reaches the screen.
---

# Brainstorming addon

## Context

Every plan Plan Mode writes on its own makes
me want to retch. This bolts three passes
onto it so the plan earns its length.

## Rules

1. SWOT the plan three times: right after
   the user's input, again mid-planning,
   and once before showing the final draft.
2. Write each SWOT down. A SWOT held in
   your head was never done.
3. Weaknesses and threats come first. The
   strengths half is the easy half.
4. A threat with no mitigation stays in the
   plan as an open risk, named as one.
5. Run unslop over the plan file before it
   is shown.
6. The plan is under 80 lines, each line
   under 80 columns.
7. Cut any step that restates CLAUDE.md or
   a skill already in `skills/`.
8. Every step names the file it touches.
   "Refactor the module" is not a step.
9. Every step names what proves it worked:
   a command, a test, a thing to look at.
10. No step credits a model, a session
    link, or a Co-Authored-By trailer.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "One SWOT is enough" | The first one is written before the plan exists. It cannot judge it. |
| "The plan is short, skip unslop" | Short slop is still slop, and it is what the user reads. |
| "80 lines is too tight for this feature" | Then the feature is more than one plan. Split it. |
| "Verification is obvious" | If it were, writing it down would cost one line. |

## Target audience

- **fucking don't care**: approves whatever
  Plan Mode emitted.
- **don't care**: skims it for the file
  list.
- **care**: reads every step.
- **really care**: rejects the plan over
  one unverifiable step.
- **Matus**: the last two, and notices the
  em-dashes.

## Post-run checklist

- [ ] Three SWOTs written down?
- [ ] Under 80 lines, under 80 columns?
- [ ] Did unslop run over the plan file?
- [ ] Does every step name a file and a way
      to check it?
- [ ] Any open risk left unnamed?
