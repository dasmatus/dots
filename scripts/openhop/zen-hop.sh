#!/bin/bash
# zen hop — manual identity rotation. deletes the current warp registration,
# registers fresh, reconnects. you land on a new IPv6 /64 (= new quota bucket).
#
# the keeper is paused during the hop — otherwise its 45s tick races us and
# "helpfully" repairs the tunnel mid-surgery. the kill-switch chain stays
# installed the whole time (keeper owns it but doesn't remove it on stop),
# so there is no leak window. keeper resumes on exit no matter what.
set -u

# warp binary: env → PATH → common fallbacks. probe with/without --accept-tos
# (shimmed boxes pass it twice = dead CLI).
WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/bin/warp-cli ]; then WARP=/usr/bin/warp-cli
  elif [ -x "$HOME/.local/bin/warp-cli" ]; then WARP="$HOME/.local/bin/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }

KEEPER="${OUC_KEEPER_UNIT:-opencode-unlimited-keeper}"
# warp-cli works without root on most installs; sudo -n (the installer's sudoers rule) as a fallback
w(){  "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0
      sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0
      sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" --accept-tos "$@" 2>/dev/null; }

restore(){ sudo -n systemctl start "$KEEPER" >/dev/null 2>&1 || sudo systemctl start "$KEEPER" >/dev/null 2>&1; }
trap restore EXIT

# Same mode as the keeper and guard: WARP as a local proxy (port 40000) unless OUC_WARP_MODE=warp on a desktop.
# (This used to switch desktops to full-tunnel mode, which changed the whole PC's routing.)
IS_VPS=0
if [ -f /etc/opencode-unlimited-vps.flag ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ]    || [ -f /etc/cloud/cloud.cfg ] || [ -d /var/lib/cloud ]; then
  IS_VPS=1
fi
MODE="${OUC_WARP_MODE:-proxy}"
[ "$IS_VPS" = "1" ] && MODE=proxy

# the address OpenCode really leaves with
cur_v6(){
  if [ "$MODE" = "warp" ]; then
    timeout 10 curl -s -m 8 https://api64.ipify.org 2>/dev/null
  else
    timeout 10 curl -x socks5h://127.0.0.1:40000 -s -m 8 https://api64.ipify.org 2>/dev/null
  fi
}

OLD_V6=$(cur_v6)
echo "old /64: ${OLD_V6:-?}"

sudo -n systemctl stop "$KEEPER" >/dev/null 2>&1 || sudo systemctl stop "$KEEPER" >/dev/null 2>&1
echo "-- rotating (keeper paused) --"
w disconnect
w registration delete
NEW=0
for i in 1 2 3 4 5; do
  w registration new && { NEW=1; break; }
  echo "  attempt $i failed"; sleep 8
done
[ "$NEW" = 1 ] || { echo "-- registration failed — keeper will keep retrying --"; exit 1; }
if [ "$MODE" = "warp" ]; then
  w mode warp
else
  w mode proxy
  w proxy port 40000
fi
w connect

for i in $(seq 1 20); do
  sleep 3
  wo status | head -1 | grep -q Connected && break
done

NEW_V6=$(cur_v6)
echo "new /64: ${NEW_V6:-?}"
if [ "$NEW_V6" != "$OLD_V6" ] && [ -n "$NEW_V6" ]; then
  # Clear client-side rate limit lockouts from drafts.sqlite
  for db in "$HOME/.config/ai.opencode.desktop/drafts.sqlite" "$HOME/.local/share/opencode/drafts.sqlite"; do
    [ -f "$db" ] && sqlite3 "$db" "DELETE FROM state WHERE key IN ('free-limit', 'go-upsell') OR key LIKE '%free%limit%' OR key LIKE '%quota%exceeded%' OR key LIKE '%upsell%';" >/dev/null 2>&1 || true
  done
  echo "== FRESH /64 ✓ — type 'continue' in your chat (or re-send your message) =="
  exit 0
fi
echo "== cloudflare handed back the same block — run me again =="
exit 1
