---
name: planning-over-brainstorming
description: Use when a feature is about to be built, added, or modified and the next step is invoking the brainstorming skill directly from normal mode. Also applies when plan mode is being skipped as "only for big tasks."
---

# Planning over brainstorming

## Context

Brainstorming works best inside plan mode: no file edits happen there, so exploring intent is safe and reversible. Brainstorming's output is requirements, exactly the input a plan needs.

## Rule

When creative work starts (build/add/modify a feature), do this in order:

1. Enter plan mode first.
2. Invoke `superpowers:brainstorming` inside plan mode.
3. Write the plan.

Never invoke `superpowers:brainstorming` from normal mode, even if a prior instruction says to invoke it before anything else. If the harness exposes no plan mode, state the plan in a message and get approval before any edit.

## Rationalizations to reject

| Excuse | Reality |
|---|---|
| "Brainstorming must run before anything else, including plan mode" | Entering plan mode first doesn't skip brainstorming; plan mode houses it. |
| "Plan mode is only for big tasks" | Any build/add/modify request qualifies, regardless of size. |
| "The user said to just build it" | A request to move fast is not a request to skip approval; plan mode is where speed is safe. |
