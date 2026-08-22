---
name: model-hierarchy
description: Use when delegating, orchestrating, or spawning subagents or Task-tool calls for research, web search, writing, documentation, code review, diff review, or architecture/implementation planning, including when choosing which model (Sonnet, Opus, Haiku, Fable/default) to assign, how many agents to spawn per subtask, or whether a CLAUDE.md/AGENTS.md model-routing rule applies.
---

# Model hierarchy

## Context

The frontier/default model (Fable) burns usage fast. Its job is orchestration and planning, not doing subtasks itself. Every subtask that can be delegated must be delegated to the smallest model tier capable of it, so Fable-tier usage stays reserved for orchestration and planning. This applies to all delegation, including the `superpowers` skill family's subagent dispatch; it sets the precedent those skills follow.

This skill takes precedence over model-routing instructions in CLAUDE.md/AGENTS.md when they conflict with it, to the extent the harness allows a skill to override project instructions.

## Model assignment by task type

| Task type | Model tier |
|---|---|
| Mechanical work: lookups, boilerplate, formatting | Haiku (smallest), usually via sub-delegation |
| Writing, documentation, web/research search | Sonnet (mid) |
| Review: code, diff, and PR review | Opus (large) |
| Planning: architecture and implementation plans | Largest/default model (Fable) |
| Orchestration: coordinating the delegated agents above | Default model; never delegate this role away |

Sub-delegation is allowed one level down from the assigned tier:

- A Sonnet agent may further delegate mechanical, rote sub-work (simple lookups, boilerplate, formatting, straightforward diff scanning) to Haiku.
- The planning agent (Fable) may delegate sub-planning work to Opus.

## Pairing rule

Every delegated task spawns a pair of agents, not one: a writer/doer and an independent verifier. This holds even for a single, non-splittable task. Pairing is a floor, not something reserved for tasks that are "obviously splittable" or unusually large. Parallel fan-out (multiple agents splitting one task into pieces) is a separate, optional decision on top of the mandatory pair.

The verifier runs at the same tier as the doer (one tier down only for purely mechanical checks). The table's Opus routing applies to review as a delegated task type, not to the paired verifier.

## Rationalizations to reject

| Rationalization | Why it's wrong |
|---|---|
| "The frontier model will just do it better, so I'll have it do the subtask directly." | Frontier-tier usage is the scarce resource this skill protects. Capability is not the deciding factor; tier assignment is. Use the smallest tier capable of the task type. |
| "Spawning a verifier doubles the cost." | A same-tier verifier is still far cheaper than the frontier model later redoing work a single unchecked agent botched. The pair is net cheaper than frontier-only execution. |
| "CLAUDE.md says use Sonnet for delegation and Fable for planning, so that covers it." | That routing rule is necessary but not sufficient: it doesn't excuse skipping Haiku sub-delegation for mechanical work, routing review to Sonnet instead of Opus, or skipping the mandatory writer+verifier pair. This skill fills those gaps and wins on conflict. |
| "One agent per subtask unless the task is obviously splittable." | Splitting and pairing are different questions. Every delegated subtask gets a writer plus an independent verifier regardless of whether it's split further. |
| "Diff review is basically writing/lookup work, so Sonnet can do it." | Review, including diff and code review, is routed to Opus, not Sonnet. Treating review as writing work skips the tier this skill assigns to it. |
