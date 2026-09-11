#!/usr/bin/env bash
# Open a new zellij pane running a headless `claude -p` session, writing its
# JSON result to a file and a `.done` sentinel on completion. Used by the
# zellij-subagents skill so each subagent task gets its own watchable pane.
#
# Usage: zellij-subagent.sh <pane-name> <result-json> <prompt-file>
#
# Requires: a running zellij session (the caller's shell inherits $ZELLIJ);
# zellij >= 0.40 for `zellij action new-pane --name`.
set -euo pipefail

name="${1:?usage: zellij-subagent.sh <pane-name> <result-json> <prompt-file>}"
result="${2:?missing result-json path}"
prompt="${3:?missing prompt-file path}"

mkdir -p "$(dirname "$result")"

# zellij action targets the current session and returns immediately (non-
# blocking), so the orchestrator can open several panes in sequence. The pane
# runs claude headless; stdout (the JSON result) is redirected to $result, and
# a .done sentinel is touched when claude exits so the orchestrator can poll.
# NB: omit --close-on-exit/--close-on_exit entirely: on zellij 0.44.3 it is a
# boolean flag taking NO value (so `--close-on-exit false` is a hard parse
# error), and its presence means close-on-exit=true, the opposite of the
# watchable-subagent intent. The default (flag absent) keeps the pane open.
zellij action new-pane \
  --name "$name" \
  -- bash -c "claude -p \"\$(cat '$prompt')\" > '$result'; touch '$result.done'"