#!/usr/bin/env bash
# Controller for the eww app launcher.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
EWW_BIN="eww"
WINDOW="launcher"

is_open() {
  $EWW_BIN active-windows 2>/dev/null | grep -qx "$WINDOW"
}

update_apps() {
  local query="$1"
  local apps
  apps=$("$SCRIPT_DIR/list-apps.sh" "$query")
  $EWW_BIN update launcher_apps="$apps"
}

case "${1:-toggle}" in
  toggle)
    if is_open; then
      $EWW_BIN close "$WINDOW"
    else
      $EWW_BIN update launcher_query='' launcher_selected=0
      update_apps ''
      $EWW_BIN open "$WINDOW"
    fi
    ;;
  search)
    query="${2:-}"
    $EWW_BIN update launcher_query="$query"
    update_apps "$query"
    ;;
  select)
    index="${2:-0}"
    $EWW_BIN update launcher_selected="$index"
    ;;
  launch)
    index="${2:-$($EWW_BIN get launcher_selected 2>/dev/null || echo 0)}"
    app=$($EWW_BIN get launcher_apps 2>/dev/null | jq -r --argjson idx "$index" '.[$idx] // empty')
    [[ -z "$app" ]] && { $EWW_BIN close "$WINDOW" >/dev/null 2>&1 || true; exit 0; }

    desktop=$(printf '%s' "$app" | jq -r '.desktop')
    [[ -z "$desktop" || ! -f "$desktop" ]] && { $EWW_BIN close "$WINDOW" >/dev/null 2>&1 || true; exit 0; }

    # Launch the selected .desktop entry and dismiss the window.
    dex "$desktop" >/dev/null 2>&1 &
    disown

    $EWW_BIN update launcher_query=''
    $EWW_BIN close "$WINDOW"
    ;;
  close)
    $EWW_BIN update launcher_query=''
    $EWW_BIN close "$WINDOW" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Usage: $0 {toggle|search|select|launch|close}" >&2
    exit 1
    ;;
esac
