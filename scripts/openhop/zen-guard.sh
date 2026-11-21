#!/bin/bash
# zen guard (Linux): watches OpenCode's log for the free-usage wall, gets a new WARP address,
# and sends 'continue' to the chats that were cut off. Same rules as the Windows app:
#
#   - a used-up /64 is skipped until OpenCode's daily reset (~01:05 UTC), not forever
#     (a lifetime list ends in "everything blacklisted" after a busy day)
#   - if new addresses keep hitting the limit within 3 min, look for the next one right away;
#     after 15 in a row, pause 3 min (WARP's shared addresses are used up: try Tor)
#   - 'continue' goes to every chat whose last message is the limit error, through the real
#     opencode binary (not our wrapper) and through WARP
#   - chats already stuck when the guard starts (limit hit before it ran) are rescued too
#   - WARP keeps the mode the installer/keeper chose (local proxy by default): the guard never
#     switches the whole PC into the tunnel
set -u

LOGF="$HOME/.local/share/opencode/log/opencode.log"
DEST="$HOME/.local/share/opencode-unlimited"
STATE_DIR="$DEST/guard"
STATE="$STATE_DIR/state.json"
GUARD_LOG="$STATE_DIR/guard.log"
LIB="$STATE_DIR/guardlib.py"

WARP="${OUC_WARP_BIN:-}"
if [ -z "$WARP" ]; then
  if command -v warp-cli >/dev/null 2>&1; then WARP="$(command -v warp-cli)"
  elif [ -x /usr/bin/warp-cli ]; then WARP=/usr/bin/warp-cli
  elif [ -x "$HOME/.local/bin/warp-cli" ]; then WARP="$HOME/.local/bin/warp-cli"
  fi
fi
[ -n "$WARP" ] || { echo "warp-cli not found"; exit 1; }
KEEPER="${OUC_KEEPER_UNIT:-opencode-unlimited-keeper}"

POLL=10            # seconds between log checks
COOLDOWN=75        # normal gap between rotations
HUNT_GAP=10        # gap while looking for an address that isn't used up yet
MAX_HOP_TRIES=8    # registrations per rotation before recycling the oldest block

mkdir -p "$STATE_DIR"

# warp-cli works without root on Linux; sudo -n only as a fallback, never a password prompt
# (this runs as a service: an interactive sudo would just hang or fail).
w(){  "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0
      sudo -n "$WARP" --accept-tos "$@" >/dev/null 2>&1 && return 0
      sudo -n "$WARP" "$@" >/dev/null 2>&1; }
wo(){ "$WARP" --accept-tos "$@" 2>/dev/null && return 0; sudo -n "$WARP" --accept-tos "$@" 2>/dev/null; }
svc(){ sudo -n systemctl "$@" >/dev/null 2>&1 || true; }

glog(){ echo "$(date '+%m-%d %H:%M:%S') $*" >> "$GUARD_LOG"; }

# Same mode as warp-keeper.sh: local proxy (port 40000) unless OUC_WARP_MODE=warp on a desktop.
IS_VPS=0
if [ -f /etc/opencode-unlimited-vps.flag ] || [ -f "$DEST/vps.flag" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ] \
   || [ -n "${SSH_CONNECTION:-}" ] || [ -f /etc/cloud/cloud.cfg ] || [ -d /var/lib/cloud ]; then
  IS_VPS=1
fi
MODE="${OUC_WARP_MODE:-proxy}"
[ "$IS_VPS" = "1" ] && MODE=proxy

set_mode(){
  if [ "$MODE" = "warp" ]; then w mode warp; else w mode proxy; w proxy port 40000; fi
}

# The address OpenCode really leaves with: through WARP's local proxy in proxy mode, direct in full-tunnel mode.
cur_v6(){
  if [ "$MODE" = "warp" ]; then
    timeout 10 curl -s -m 8 https://api64.ipify.org 2>/dev/null
  else
    timeout 10 curl -x socks5h://127.0.0.1:40000 -s -m 8 https://api64.ipify.org 2>/dev/null
  fi
}

# ---------------------------------------------------------------- python helper (state, rules, resume)
cat > "$LIB" <<'PY'
import calendar, json, os, re, signal, sqlite3, subprocess, sys, time
from pathlib import Path

HOME = Path.home()
STATE = HOME / ".local/share/opencode-unlimited/guard/state.json"
DB = HOME / ".local/share/opencode/opencode.db"
REWALL = 180          # the limit back this soon after a new IP = that IP was already used up
FAILED_MAX = 15       # then pause
PAUSE = 180
STUCK_LOOKBACK = 30 * 60
CONTINUE_MAX_AGE = 30 * 60


def load():
    try:
        d = json.loads(STATE.read_text())
    except Exception:
        d = {}
    d.setdefault("blacklist", []); d.setdefault("burnt_until", {}); d.setdefault("offset", 0)
    for k in ("last_hop", "last_ok_hop", "hops", "failed_hops", "backoff_until", "hop_counted"):
        d.setdefault(k, 0)
    d.setdefault("current", "")
    return d


def save(d):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(d))
    os.replace(tmp, STATE)


def m64(a):
    return ":".join((a or "").strip().lower().split(":")[:4])


def next_reset(now):
    """Next ~01:05 UTC: OpenCode's per-IP counters reset between 00:00 and 01:00 UTC."""
    t = time.gmtime(now)
    today = calendar.timegm((t.tm_year, t.tm_mon, t.tm_mday, 1, 5, 0, 0, 0, 0))
    return today if today > now else today + 86400


def burn(d, addr, now):
    p = m64(addr)
    if not p or ":" not in p:
        return
    bu = {k: v for k, v in d["burnt_until"].items() if float(v) > now}
    bu[p] = next_reset(now)
    d["burnt_until"] = dict(list(bu.items())[-200:])
    d["blacklist"] = list(d["burnt_until"].keys())  # doctor.sh counts this list


def burnt(d, addr, now):
    return float(d["burnt_until"].get(m64(addr), 0) or 0) > now


def note_wall(d, now):
    """'pause' (don't rotate), 'hunt' (rotate soon: the new IP was used up) or 'normal'."""
    if d["backoff_until"] and now >= d["backoff_until"]:
        d["backoff_until"] = 0
        d["failed_hops"] = 0
        print("LOG rotation pause is over, trying again")
    if now < d["backoff_until"]:
        return "pause"
    last = int(d["last_ok_hop"] or 0)
    if last and now - last <= REWALL:
        if d["hop_counted"] != last:
            d["hop_counted"] = last
            d["failed_hops"] += 1
            print(f"LOG limit came back {now - last}s after the last IP change (failed attempt {d['failed_hops']} of {FAILED_MAX})")
    elif last:
        d["failed_hops"] = 0
    if d["failed_hops"] >= FAILED_MAX:
        d["backoff_until"] = now + PAUSE
        print(f"LOG pausing for {PAUSE // 60} min: the last {FAILED_MAX} new addresses were already used up by other "
              "people (WARP's shared addresses are busy right now). Tor (other addresses) works around it.")
        return "pause"
    return "hunt" if d["failed_hops"] > 0 else "normal"


def stuck(max_age=STUCK_LOOKBACK):
    """Chats whose latest message is the free-limit error from the last max_age seconds."""
    if not DB.is_file():
        return []
    since = (time.time() - max_age) * 1000
    try:
        con = sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True, timeout=3.0)
        try:
            rows = con.execute(
                "SELECT m.session_id, m.data FROM session_message m JOIN ("
                "  SELECT session_id, MAX(seq) AS s FROM session_message WHERE session_id IN ("
                "    SELECT DISTINCT session_id FROM session_message WHERE type = 'idle' AND time_created >= ?"
                "  ) GROUP BY session_id"
                ") last ON m.session_id = last.session_id AND m.seq = last.s"
                " WHERE m.type = 'idle' AND m.time_created >= ?", (since, since)).fetchall()
        finally:
            con.close()
    except Exception:
        return []
    return [str(s) for s, data in rows if s and "provider.free-limit" in str(data or "")]


def real_opencode():
    """The real opencode binary, never our wrapper (~/.local/bin/opencode runs zen-lane.sh)."""
    cands = [os.environ.get("OUC_REAL_BIN", ""), str(HOME / ".opencode/bin/opencode"),
             str(HOME / ".local/share/opencode-unlimited/real-opencode"), "/usr/local/bin/opencode", "/usr/bin/opencode"]
    for c in cands:
        if not c or not os.path.isfile(c) or not os.access(c, os.X_OK):
            continue
        try:
            head = open(c, "rb").read(4096)
        except OSError:
            continue
        if b"zen-lane.sh" in head:
            continue
        return c
    return ""


def kill_stale(oc, sids):
    """Our earlier 'continue' runs: the ones for these chats, and any older than 30 min ('opencode run' can stay open for hours)."""
    try:
        out = subprocess.run(["ps", "-eo", "pid=,etimes=,args="], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[1].isdigit():
            continue
        pid, age, args = int(parts[0]), int(parts[1]), parts[2]
        if " run " not in f" {args} " or not args.rstrip().endswith("continue") or os.path.basename(oc) not in args:
            continue
        if age > CONTINUE_MAX_AGE or any(s in args for s in sids):
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass


def clear_drafts():
    for db in (HOME / ".config/ai.opencode.desktop/drafts.sqlite", HOME / ".local/share/opencode/drafts.sqlite"):
        if db.is_file():
            try:
                c = sqlite3.connect(str(db), timeout=3.0)
                c.execute("DELETE FROM state WHERE key IN ('free-limit', 'go-upsell') OR key LIKE '%free%limit%'")
                c.commit(); c.close()
            except Exception:
                pass


def resume(mode):
    clear_drafts()
    oc = real_opencode()
    if not oc:
        print("LOG [auto-resume] the opencode binary wasn't found, so no 'continue' was sent")
        return
    env = dict(os.environ)
    proxy = ""
    if mode != "warp":  # same as zen-lane.sh: openhop's proxy if it runs, else WARP's port (it speaks HTTP proxy too)
        import socket
        proxy = "http://127.0.0.1:40000"
        try:
            socket.create_connection(("127.0.0.1", 41987), timeout=0.5).close()
            proxy = "http://127.0.0.1:41987"
        except OSError:
            pass
    if proxy:
        for k in ("ALL_PROXY", "all_proxy"):
            env.pop(k, None)
        for k in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"):
            env[k] = proxy
        env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost,::1"
    sids = stuck()
    kill_stale(oc, sids)
    db_dir = {}
    try:
        con = sqlite3.connect(f"file:{DB.as_posix()}?mode=ro", uri=True, timeout=3.0)
        for s in sids:
            r = con.execute("SELECT directory FROM session_v2 WHERE id = ?", (s,)).fetchone()
            if r and r[0] and os.path.isdir(r[0]):
                db_dir[s] = r[0]
        con.close()
    except Exception:
        pass
    sent = 0
    for s in sids:
        try:
            subprocess.Popen([oc, "run", "--session", s, "continue"], cwd=db_dir.get(s), env=env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
            sent += 1
        except Exception as exc:
            print(f"LOG [auto-resume] {s[:12]}: {exc}")
    if sids:
        print(f"LOG [auto-resume] new IP -> sent 'continue' to {sent} of {len(sids)} chat(s) stopped at the limit")
        return
    try:  # nothing found in the database (older OpenCode): the latest chat, like before
        subprocess.Popen([oc, "run", "--continue", "continue"], env=env, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        print("LOG [auto-resume] new IP -> sent 'continue' to the latest chat")
    except Exception as exc:
        print(f"LOG [auto-resume] {exc}")


def main(argv):
    cmd, now = argv[1], int(time.time())
    d = load()
    if cmd == "get":
        print(d.get(argv[2], ""))
    elif cmd == "set":
        d[argv[2]] = int(argv[3]) if re.fullmatch(r"-?\d+", argv[3]) else argv[3]
        save(d)
    elif cmd == "burn":
        burn(d, argv[2], now); save(d)
    elif cmd == "burnt":
        sys.exit(0 if burnt(d, argv[2], now) else 1)
    elif cmd == "recycle":  # every address came back used up: forget the one that resets first
        if d["burnt_until"]:
            oldest = min(d["burnt_until"], key=lambda k: d["burnt_until"][k])
            d["burnt_until"].pop(oldest, None)
            d["blacklist"] = list(d["burnt_until"].keys())
            save(d)
    elif cmd == "wall":
        print("ACTION " + note_wall(d, now)); save(d)
    elif cmd == "hopped":
        d.update(last_hop=now, last_ok_hop=now, current=argv[2], hops=int(d["hops"]) + 1); save(d)
        print(d["hops"])
    elif cmd == "failed":
        d["last_hop"] = now; save(d)
    elif cmd == "stuck":
        print(" ".join(stuck()))
    elif cmd == "resume":
        resume(argv[2] if len(argv) > 2 else "proxy")


if __name__ == "__main__":
    main(sys.argv)
PY

lib(){ python3 "$LIB" "$@" 2>/dev/null; }
# lines starting with LOG go to guard.log, the rest is the answer
libl(){ local out; out="$(lib "$@")"; printf '%s\n' "$out" | sed -n 's/^LOG //p' | while IFS= read -r l; do glog "$l"; done
        printf '%s\n' "$out" | grep -v '^LOG ' ; }

hop_once(){
  # one registration cycle; prints the new address or nothing.
  svc stop "$KEEPER"
  w disconnect
  w registration delete
  local ok=0 i
  for i in 1 2 3; do
    w registration new && { ok=1; break; }
    sleep 6
  done
  set_mode
  w connect
  svc start "$KEEPER"
  [ "$ok" = 1 ] || { echo ""; return; }
  local V=""
  for i in $(seq 1 12); do
    sleep 3
    V=$(cur_v6)
    [ -n "$V" ] && break
    V=""
  done
  echo "$V"
}

rotate(){
  local OLD NEW V TRY H
  OLD=$(cur_v6)
  glog "wall detected — rotating WARP /64 (was: ${OLD:-?})"
  [ -n "$OLD" ] && lib burn "$OLD"
  NEW=""
  TRY=0
  while [ "$TRY" -lt "$MAX_HOP_TRIES" ]; do
    TRY=$((TRY + 1))
    V=$(hop_once)
    if [ -z "$V" ]; then glog "try $TRY: tunnel repair failed"; continue; fi
    if lib burnt "$V"; then glog "try $TRY: cloudflare returned a used-up /64 ($V) — again"; continue; fi
    NEW="$V"; break
  done
  if [ -z "$NEW" ]; then
    glog "every address tried is used up until the daily reset — reusing the one that resets first"
    lib recycle
    V=$(hop_once)
    [ -n "$V" ] && NEW="$V"
  fi
  if [ -n "$NEW" ]; then
    H=$(lib hopped "$NEW")
    glog "rotated #$H: ${OLD:-?} -> $NEW ✓"
    sleep 3   # let old connections close before the 'continue'
    libl resume "$MODE" >/dev/null
  else
    lib failed
    glog "rotation failed — the keeper keeps the tunnel alive; trying again on the next limit"
  fi
}

# fresh state: start reading from the end of the current log
if [ ! -f "$STATE" ]; then
  OFF=0; [ -f "$LOGF" ] && OFF=$(wc -c < "$LOGF")
  lib set offset "$OFF"
fi

glog "zen-guard up (poll ${POLL}s, cooldown ${COOLDOWN}s, mode $MODE)"

# A limit hit while the guard wasn't running (just installed, or restarting) is never written to the log again.
if [ -n "$(lib stuck)" ]; then
  NOW=$(date +%s); LASTHOP=$(lib get last_hop); LASTHOP=${LASTHOP:-0}
  if [ $((NOW - LASTHOP)) -ge "$COOLDOWN" ]; then
    glog "chats were already stopped at the free limit when the guard started — getting a new IP"
    rotate
  fi
fi

while true; do
  sleep "$POLL"
  [ -f "$LOGF" ] || continue
  SIZE=$(wc -c < "$LOGF" 2>/dev/null || echo 0)
  OFF=$(lib get offset); OFF=${OFF:-0}
  [ "$SIZE" -lt "$OFF" ] && OFF=0   # log rotated
  NEWBYTES=$((SIZE - OFF))
  WALL=0
  if [ "$NEWBYTES" -gt 0 ] && [ "$NEWBYTES" -lt 50000000 ]; then
    if tail -c +"$((OFF + 1))" "$LOGF" 2>/dev/null | head -c "$NEWBYTES" | grep -E -aqi \
       "QuotaExceeded|quota_exceeded|Free usage limit|usage limit reached|Rate limit|rate_limit|too many requests|status=429|\"status\":429|credits exhausted|free-tier usage"; then
      WALL=1
    fi
  fi
  lib set offset "$SIZE"
  [ "$WALL" = 1 ] || continue

  ACTION=$(libl wall | sed -n 's/^ACTION //p')
  [ "$ACTION" = "pause" ] && continue
  NOW=$(date +%s); LASTHOP=$(lib get last_hop); LASTHOP=${LASTHOP:-0}
  AGE=$((NOW - LASTHOP))
  if [ "$AGE" -ge "$COOLDOWN" ] || { [ "$ACTION" = "hunt" ] && [ "$AGE" -ge "$HUNT_GAP" ]; }; then
    [ "$ACTION" = "hunt" ] && [ "$AGE" -lt "$COOLDOWN" ] && glog "that address was already used up — trying the next one right away"
    rotate
  else
    glog "wall seen but in cooldown (${AGE}s < ${COOLDOWN}s) — waiting"
  fi
done
