#!/usr/bin/env bash
# First-login keybind cheatsheet controller. Opens once after a fresh install,
# then writes a sentinel so it never auto-appears again. --force skips the
# sentinel, making the sheet recallable on demand (bound to SUPER + /).
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dots"
SENTINEL="$STATE/keybinds-shown"

if [[ $FORCE -eq 0 && -f "$SENTINEL" ]]; then
  exit 0
fi
[[ $FORCE -eq 0 ]] && sleep 2

EWW_BIN="eww"
WINDOW="keybinds"

if $EWW_BIN active-windows 2>/dev/null | grep -qx "$WINDOW"; then
  $EWW_BIN close "$WINDOW"
else
  $EWW_BIN open "$WINDOW"
fi

mkdir -p "$STATE"
touch "$SENTINEL"
