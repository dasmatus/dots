#!/usr/bin/env bash
# Enumerate GUI .desktop applications and emit a filtered JSON list for eww.
set -euo pipefail

QUERY="${1:-}"
QUERY_LC=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
EWW_BIN="eww"

# Collect XDG applications directories.
mapfile -t APP_DIRS < <(
  printf '%s' "${XDG_DATA_DIRS:-/usr/share:/usr/local/share}" \
    | tr ':' '\n' \
    | awk '{ print $0 "/applications" }' \
    | sort -u
)

# Add ~/.local/share/applications explicitly in case it is missing.
LOCAL_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
[[ -d "$LOCAL_APPS" ]] && APP_DIRS+=("$LOCAL_APPS")

declare -A SEEN
entries=()

for dir in "${APP_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' file; do
    base=$(basename "$file")
    [[ -n "${SEEN[$base]:-}" ]] && continue
    SEEN[$base]=1

    # First Name/Icon/Exec/Hidden/NoDisplay/Terminal lines only.
    name=$(grep -m1 '^Name=' "$file" 2>/dev/null | cut -d= -f2- || true)
    icon=$(grep -m1 '^Icon=' "$file" 2>/dev/null | cut -d= -f2- || true)
    exec=$(grep -m1 '^Exec=' "$file" 2>/dev/null | cut -d= -f2- || true)
    hidden=$(grep -m1 '^Hidden=' "$file" 2>/dev/null | cut -d= -f2- || true)
    nodisplay=$(grep -m1 '^NoDisplay=' "$file" 2>/dev/null | cut -d= -f2- || true)
    terminal=$(grep -m1 '^Terminal=' "$file" 2>/dev/null | cut -d= -f2- || true)

    [[ -z "$name" ]] && continue
    [[ "$hidden" == "true" || "$nodisplay" == "true" || "$terminal" == "true" ]] && continue

    if [[ -n "$QUERY_LC" ]]; then
      name_lc=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
      [[ "$name_lc" == *"$QUERY_LC"* ]] || continue
    fi

    entries+=("$(
      jq -n \
        --arg name "$name" \
        --arg icon "$icon" \
        --arg desktop "$file" \
        --arg exec "$exec" \
        '{name:$name, icon:$icon, desktop:$desktop, exec:$exec}'
    )")
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -name '*.desktop' -type f -print0 2>/dev/null)
done

if (( ${#entries[@]} > 0 )); then
  printf '%s\n' "${entries[@]}" \
    | jq -s 'sort_by(.name | ascii_downcase)[:20] | to_entries | map(.value + {index: .key})'
else
  echo '[]'
fi
