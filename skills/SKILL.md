---
name: skills
description: Use when working in this repository and a task involves device porting, planning, delegation, Rust, C or C++, Nix, installer changes, web code, memory, skill authoring, or forge-facing text.
---

# Tokyo Night Dots skills

## Context

This collection provides local engineering
guidance. Read the relevant guide before work;
read more than one for cross-domain tasks.

## Rules

1. Read matching guides before acting. Paths are
   relative to this file.
2. For device porting or flashing, read
   `automated-device-porting/SKILL.md`.
3. For planning, read
   `planning-over-brainstorming/SKILL.md`.
   While drafting a plan, also read
   `brainstorming-addon/SKILL.md`.
4. Before delegation, read
   `model-hierarchy/SKILL.md` and
   `subagent-driven-by-default/SKILL.md`.
5. For compiled or systems code, read
   `writing-good-code/SKILL.md`.
6. For Rust, also read `writing-good-rs/SKILL.md`.
7. For C or C++, read `writing-good-cpp/SKILL.md`.
   For compiler choices, also read
   `c-compiler-preference/SKILL.md`.
8. For Nix flakes or toolchains, read
   `nix-flake-preference/SKILL.md`.
9. For installer or LiveISO changes, read
   `writing-good-installer/SKILL.md`.
10. For browser or web code, read
    `writing-good-web/SKILL.md`.
11. Before creating or changing a skill, read
    `skill-template/SKILL.md`.
12. For memory changes, read
    `unslopping-memory/SKILL.md`.
13. Before forge-facing text or attribution, read
    `dodging-cdb/SKILL.md`.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "I know the convention already" | Check the guide for this repo. |
| "This task has only one part" | One domain still has a guide. |
| "The task spans domains" | Read each applicable guide. |

## Target audience

Tiers calibrate how much guidance to load,
never whether its rules apply.

- **New to the repo**: read the matching guide.
- **Familiar with the repo**: check its triggers
  anyway.
- **Experienced**: follow every applicable guide.

## Post-run checklist

- [ ] Did you read each applicable guide?
- [ ] Did the work follow those guides?
- [ ] Are the referenced paths present?
