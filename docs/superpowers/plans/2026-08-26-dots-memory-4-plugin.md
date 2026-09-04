# Dots Memory 4: Plugin Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Package the memory MCP and hooks as a plugin that loads,
digests on start, and nudges on stop.
**Architecture:** a checked-in JSON tree under `plugins/dots-memory/`
stays diffable; a `runCommand` adds `bin/` store symlinks on top.
**Tech Stack:** Claude Code plugin schema, Nix `writeShellApplication`,
`runCommand`, `postgresql_18` client.
**Spec:** `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`

## Global Constraints
- Needs plan 3's `packages.dots-memory-mcp`; the digest needs plan 2
  live in Postgres, else the hook degrades to empty output.
- `plugin.json` `author` MUST be an object; a string hard-fails.
- `.mcp.json` wraps `{"mcpServers": {...}}`; `hooks/hooks.json` wraps
  `{"hooks": {...}}`; inverting either loads zero hooks silently.
- Both files use `${CLAUDE_PLUGIN_ROOT}/bin/<name>`, never a store path.
- Hooks return `hookSpecificOutput` with `hookEventName` and
  `additionalContext`; a Postgres failure exits 0, never exit 2.
- OPEN RISK: `dodging-cdb`'s SessionStart hook (`claude.nix:202-211`)
  and this digest merge with no dedup, ~2300 tokens combined.
- Only `SKILL.md` hot-reloads; the other two need `/reload-plugins`.
  No `settings.enabledPlugins` entry (names `<plugin>@<marketplace>`).
- Taken names: the 12 repo skills, `pstack`,
  `claude-code-home-manager`; a collision fails two HM assertions.
- No `pkgs.symlinkJoin` (`lib.nix:52-57`): its `agents/`/`commands/`
  scanners accept regular files only.
- `claude.nix:266` already ends on an orphaned comment; leave it be.

---
### Task 1: Scaffold the checked-in plugin manifest tree
**Files:** create `plugins/dots-memory/.claude-plugin/plugin.json`,
`plugins/dots-memory/.mcp.json`, `plugins/dots-memory/hooks/hooks.json`.
**Produces:** `name` `dots-memory`, `author` an object; the MCP server
at `bin/dots-memory-mcp`; `SessionStart`/`Stop` hooks naming
`bin/dots-memory-hook` with `args` `["session-start"]`/`["stop"]`.
- [ ] **1** Write `plugin.json`, `.mcp.json`, `hooks/hooks.json`
- [ ] **2** `claude plugin validate plugins/dots-memory`
      Expected: passes on `plugin.json` (skips `hooks.json` entirely)
- [ ] **3** `git commit -m "feat: scaffold the dots-memory plugin tree"`

### Task 2: Write the memory skill
**Files:** create `plugins/dots-memory/skills/memory/SKILL.md`.
**Produces:** a skill saying WHEN to reach for `recall`/`remember`/
`forget`/`graph`; tool descriptions carry how, per skill-template.

- [ ] **1** Write `skills/memory/SKILL.md`: 12 numbered rules,
      five-rung ladder ending in Matus, 4 checklist items
- [ ] **2** Run skill-template's post-run checklist over the file
      Expected: every box true, including the under-80-lines box
- [ ] **3** `git commit -m "docs: add the memory skill"`

### Task 3: Wire the hook handler and the plugin derivation
**Files:** modify `nix/home/ai/claude.nix` (new `let`-bindings before
`programs.claude-code`; `plugins.dots-memory =` inside it).
**Produces:** `dotsMemoryHook`, a `writeShellApplication`
(`runtimeInputs = [ pkgs.postgresql_18 ]`) dispatching `$1`:
`session-start` runs `psql -X -d matus -Atc "select
agentmem.digest('$scope', 40, 6000)"` (about 1500 tokens), scope =
`basename "${CLAUDE_PROJECT_DIR:-$PWD}"`, wrapping stdout in
`hookSpecificOutput`; `stop` emits the spec section 6 nudge verbatim;
any `psql` failure exits 0 with empty stdout. `dotsMemoryPlugin`, a
`runCommand` `cp -r`ing the tree into `$out`, symlinking the plan-3
binary and the hook into `$out/bin`, asserting `$out/.claude-plugin`
and `$out/.mcp.json` survived the copy; `plugins.dots-memory`.

- [ ] **1** Add `dotsMemoryHook` to `nix/home/ai/claude.nix`
- [ ] **2** Add `dotsMemoryPlugin` and `plugins.dots-memory =` to
      `nix/home/ai/claude.nix`, with the survival assertions
- [ ] **3** `nix run .#nix-lint`
      Expected: green, no skill/plugin name-collision assertion
- [ ] **4** `home-manager switch`; fresh session, `/plugin details
      dots-memory`, read the injected context
      Expected: `Hooks (2) SessionStart, Stop`, `MCP servers (1)`,
      recalled-memory marker present (or empty if Postgres is down)
- [ ] **5** `git commit -m "feat: wire the dots-memory plugin into home"`
