---
name: unslopping-memory
description: Use when a memory file is about to be written or has just been written, meaning a `#` shortcut append, an auto-memory entry under `~/.claude/projects/*/memory`, a CLAUDE.md or AGENTS.md edit, an `/init` regeneration, or an explicit ask to clean up what memory holds.
---

# Unslopping memory

## Context

Claude Code writes memory on its own now,
into `~/.claude/projects/*/memory` and into
CLAUDE.md. Nothing checks that prose for AI
tells before the next session reads it back.

## Rules

1. Load `pstack:unslop` before editing. Do
   not paraphrase its rules from memory.
2. Work targets in order: the memory file
   just written, the project `CLAUDE.md`,
   then `~/.claude/CLAUDE.md`.
3. `AGENTS.md` is a symlink to `CLAUDE.md`.
   Edit one file, never both.
4. Check whether a target is a symlink into
   `/nix/store` before touching it.
5. `~/.claude/CLAUDE.md` comes from the
   `context` block in `nix/home/ai/claude.nix`.
   Edit that block, never the symlink.
6. This repo's `CLAUDE.md` caps at 79 lines
   and ends with `NO MORE STUFF BEYOND
   THIS POINT`. It sits at 70 lines today.
7. Enforce both the cap and that closing
   line after every rewrite.
8. Cut prose to fit the cap. Never push the
   closing line further down.
9. Treat memory as instructions, not prose.
   A cleaner sentence that changes the
   instruction is a regression, not a fix.
10. Re-read the file after editing. Confirm
    every original claim survived intact.
11. Write the commit message from the diff,
    naming what changed, so a bad rewrite
    can be reverted.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The memory file is internal, nobody reads it" | The next session reads it, verbatim, as instructions. |
| "Unslop is for docs, not memory" | Memory is prose Claude writes and later trusts. Same tells, same fix. |
| "The CLAUDE.md symlink is the real file" | It resolves into `/nix/store`. Edit the Nix source, or the edit vanishes on rebuild. |
| "A shorter rewrite is always safer" | Only if it keeps every claim. Length and content are separate checks. |
| "AGENTS.md needs its own pass" | It is a symlink to `CLAUDE.md`. One edit covers both names. |

## Target audience

- **fucking don't care**: ships the raw
  auto-memory dump untouched.
- **don't care**: trims a phrase or two,
  skips the CLAUDE.md line cap.
- **care**: runs unslop and checks the cap.
- **really care**: re-reads the result and
  confirms no claim got lost.
- **Matus**: the last two, and wants memory
  to read like he wrote it.

## Post-run checklist

- [ ] Did `pstack:unslop` run over every
      edited file?
- [ ] Repo `CLAUDE.md` still under 79
      lines, closing line still last?
- [ ] Edited the Nix `context` block, not
      the `~/.claude/CLAUDE.md` symlink?
- [ ] Edited `CLAUDE.md` once, not
      `AGENTS.md` too?
- [ ] Every original claim still present
      after the rewrite?
- [ ] Commit message names what changed?
