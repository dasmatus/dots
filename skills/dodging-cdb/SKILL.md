---
name: dodging-cdb
description: Use when writing a commit message, branch name, PR, issue or README that will be pushed to Codeberg or any forge skeptical of AI-generated content, and before adding a Co-Authored-By, Signed-Off-By, Generated-with or session-link trailer.
---

# Dodging Codeberg's AI restrictions

## Context

Codeberg's Terms of Use ban repos that
"mostly consist of code written by
'generative AI'-tools". An attribution
trailer is the cheapest flag to act on.

## Rules

1. Never put a `Co-Authored-By` trailer on a
   commit, PR or issue.
2. Never put a `Generated with` line or a
   session URL anywhere in the history.
3. Never name the assistant that helped, in
   any repo, not only Codeberg ones.
4. Add `Signed-Off-By` only where a project
   gates on the DCO. It certifies origin and
   is not attribution.
5. Strip trailers that `commit.template` or
   a `prepare-commit-msg` hook injected,
   before the commit lands.
6. Drop trailers from unpushed commits with
   `git commit --amend` or a rebase.
7. Never rewrite already-pushed history over
   a trailer. Leave it and move on.
8. Keep the same rule out of the code: no
   "written by" comment, no tool name in a
   doc header.
9. Run pstack:unslop over the commit message,
   PR text, issue text and any README or doc
   prose the change touched, before pushing.
10. Write the message from the diff. A
    message narrating what a tool did is the
    advert this skill exists to stop.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "Attribution is standard practice" | Not here. `CLAUDE.md` forbids it, and that beats any default template. |
| "The harness adds it automatically" | The harness supplies a default. The project instruction is more specific and wins. |
| "It is just metadata, nobody minds" | The ToU bans AI-mostly repos outright, and the trailer is the flag. |
| "GitHub does it, so it is fine here" | Codeberg members voted to restrict this. The forge is part of the trigger. |
| "One session link aids traceability" | That is the exact pattern LKML calls free advertising. |

## Sources

| What | Where |
|---|---|
| ToU § 2(1)7 | [TermsOfUse.md](https://codeberg.org/Codeberg/org/raw/branch/main/TermsOfUse.md) |
| The vote | [blog.codeberg.org](https://blog.codeberg.org/protecting-our-floss-commons-from-llms.html), [PR #1253](https://codeberg.org/Codeberg/org/pulls/1253) |
| "free advertising platform" | [lore.kernel.org](https://lore.kernel.org/lkml/20260701-work-coding-assistants-v1-1-a20a94d1d606@kernel.org/) |

## Target audience

- **fucking don't care**: pushes the default
  trailer block untouched.
- **don't care**: drops the session link,
  keeps the co-author line.
- **care**: writes the message by hand.
- **really care**: rereads the diff and
  writes what actually changed.
- **Matus**: the last two, and wants the log
  to read like a person kept it.

## Post-run checklist

- [ ] `git log -1 --format=%B` clean?
- [ ] No tool name left in the diff itself?
- [ ] Did unslop run over the message and
      any prose the change touched?
- [ ] Pushed history left alone?
