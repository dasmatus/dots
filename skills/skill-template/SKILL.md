---
name: skill-template
description: Use when creating, editing, reviewing or splitting a SKILL.md, writing its frontmatter, deciding its sections, or judging whether an existing skill is too long, too vague or too sloppy to keep.
---

# Writing a skill

## Context

Every skill is loaded before it has earned
its keep, so length is a tax paid on every
session. The stock guidance runs to hundreds
of lines and reads like nothing a person
would say out loud.

## Rules

1. Under 80 lines total. Prose lines under
   50 columns; a table row is exempt, since
   Markdown cannot wrap one.
2. Frontmatter carries `name` and
   `description`, nothing else. `name`
   matches the directory.
3. `description` opens with "Use when" and
   lists triggers, not the topic.
4. Context is two sentences. Say why the
   skill exists, then stop.
5. Rules are numbered, imperative, and
   there are at least ten.
6. Add a rationalization table whenever an
   agent could argue its way past a rule.
7. Add a target-audience section modelled
   on writing-good-rs.
8. Close with a post-run checklist of
   things to verify, never things to feel.
9. No em-dashes, no "delve", no "robust",
   no three-item flourishes. Run unslop
   over the finished file.
10. Never name a model, a session link or a
    Co-Authored-By line in a skill, the way
    dodging-cdb forbids it in commits.
11. Tests a skill demands go in the repo's
    `tests/`, never inline in a source file.
12. A rule that already lives in CLAUDE.md
    stays there. Do not restate it here.
13. A skill overlapping another gets merged
    into it, not shipped beside it.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The topic needs more room" | Split it or cut it. 80 lines is the budget. |
| "Prose reads better than rules" | Agents skim. Numbered imperatives survive skimming. |
| "The description explains the subject" | A description nobody can match against never fires. |
| "unslop is for user-facing prose" | A skill is read every session. That is user-facing. |

## Target audience

- **fucking don't care**: pastes the stock
  template and ships it.
- **don't care**: trims it, keeps the
  em-dashes and the boilerplate.
- **care**: rewrites the prose by hand.
- **really care**: deletes the skill once
  the rule lands somewhere better.
- **Matus**: the last three, and wants the
  file to read like he wrote it.

## Post-run checklist

- [ ] Under 80 lines, prose under 50
      columns?
- [ ] Does `description` say when, not what?
- [ ] Ten rules or more?
- [ ] Did unslop run over the whole file?
- [ ] Loaded in a fresh session and fired on
      the trigger it claims?
