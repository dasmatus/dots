---
name: zellij-subagents
description: Use when dispatching multiple subagent tasks and you want each running as a live, watchable headless `claude -p` session in its own zellij pane (one tab, one pane per subagent). Falls back to the normal in-process Agent tool when not inside a zellij session.
---

# Zellij subagent panes

Run each subagent task as a **separate headless `claude -p` session** in its own
zellij pane, so the user can watch every agent work live. One new tab holds all
the panes for the current orchestration.

## When to use

- You are about to dispatch **multiple** subagent tasks (research, parallel
  implementation, multi-file review), and
- The user is running inside a zellij session (`$ZELLIJ` is set), and
- The user wants live visibility into each agent.

If `$ZELLIJ` is unset, **do not** use this skill — fall back to the normal
in-process `Agent` tool. Headless `claude -p` panes only make sense when there
is a zellij session to attach panes to.

## Procedure

1. **Decompose** the work into N independent subagent tasks. Write each task's
   prompt to its own file under `/tmp/zellij-subagents/`:

   ```bash
   mkdir -p /tmp/zellij-subagents
   printf '%s' '<task-1 prompt>' > /tmp/zellij-subagents/1.prompt
   printf '%s' '<task-2 prompt>' > /tmp/zellij-subagents/2.prompt
   # ...
   ```

2. **Open a tab** for the orchestration:

   ```bash
   zellij action new-tab --name subagents
   ```

3. **Open one pane per task** via the helper (non-blocking; returns
   immediately):

   ```bash
   scripts/zellij-subagent.sh agent-1 /tmp/zellij-subagents/1.json /tmp/zellij-subagents/1.prompt
   scripts/zellij-subagent.sh agent-2 /tmp/zellij-subagents/2.json /tmp/zellij-subagents/2.prompt
   # ...
   ```

   Each pane runs `claude -p "$(cat <prompt>)" > <result>; touch <result>.done`.

4. **Wait for completion** by polling the `.done` sentinels (background bash):

   ```bash
   for i in 1 2; do
     while [ ! -f "/tmp/zellij-subagents/$i.json.done" ]; do sleep 2; done
   done
   ```

5. **Read the JSON results** and synthesize an answer from all of them. The
   files contain whatever the headless `claude -p` sessions wrote to stdout.

6. **Clean up** the temp files when done: `rm -f /tmp/zellij-subagents/*`.

## Notes

- zellij CLI flags evolve; `zellij action new-pane --name` and
  `zellij action new-tab --name` are stable in zellij 0.40+. Note:
  `--close-on-exit`/`-c` is a **boolean** flag (no value) that means
  close-on-exit=true — never pass `--close-on-exit false`; omit the flag to
  keep panes open. If a flag is rejected, run
  `zellij action new-pane --help` and adjust.
- Headless `claude -p` uses the user's normal auth/plan; each pane is a real
  billed session. Prefer fewer, well-scoped panes over many tiny ones.
- The helper writes results to `/tmp` (not the repo) so nothing pollutes the
  working tree.