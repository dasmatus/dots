#!/usr/bin/env bash
# Launch the dots Quickshell config under a HEADLESS sway, so testing never
# touches the real desktop.
#
# Why not a bare `qs -p`: quickshell's bars are layer-shell surfaces, so a
# bare run against the live WAYLAND_DISPLAY maps them onto the user's actual
# screen. Four stray status bars accumulated during the QML migration before
# anyone noticed, because a second bar reads as a rendering quirk rather than
# a second process.
#
# Why headless rather than nested: a nested sway still opens a window on the
# desktop. wlroots' headless backend creates a virtual output instead, so
# nothing is drawn anywhere the user can see. `grim` can still capture that
# virtual output, which is how a change gets EYEBALLED without ever being on
# screen — a blank frame is a launch failure that a clean log will not show.
#
# Usage: nested-shell-test.sh <config-dir> [root.qml]
#   config-dir  a built dots-quickshell-config store path
#   root.qml    defaults to shell.qml; pass installer.qml for the ISO root
# Env: DURATION (seconds, default 25), SHOT (path for a PNG capture)
set -u

CFG="${1:?usage: nested-shell-test.sh <config-dir> [root.qml]}"
ROOT="${2:-shell.qml}"
DURATION="${DURATION:-25}"
SHOT="${SHOT:-}"
LOG=$(mktemp -t headless-shell-XXXXXX.log)

SWAY=$(nix build nixpkgs#sway --no-link --print-out-paths 2>/dev/null)/bin/sway
QS=$(nix build nixpkgs#quickshell --no-link --print-out-paths 2>/dev/null)/bin/qs
GRIM=$(nix build nixpkgs#grim --no-link --print-out-paths 2>/dev/null)/bin/grim

# A throwaway config: one virtual output, no bar of sway's own, and our shell
# as the only client. The capture runs a few seconds in, once the shell has
# had time to paint.
SWAYCFG=$(mktemp -t headless-sway-XXXXXX.conf)
{
  echo 'output HEADLESS-1 mode 1920x1080 bg #1a1b26 solid_color'
  echo "exec \"$QS -p $CFG/$ROOT -n\""
  [ -n "$SHOT" ] && echo "exec \"sleep 6; $GRIM -o HEADLESS-1 $SHOT\""
} > "$SWAYCFG"

echo "sway:   $SWAY"
echo "qs:     $QS"
echo "config: $CFG/$ROOT"
echo "log:    $LOG"
[ -n "$SHOT" ] && echo "shot:   $SHOT"
echo "--- headless session start (${DURATION}s) ---"

# WAYLAND_DISPLAY and DISPLAY are UNSET on purpose: with them set, wlroots
# picks the wayland backend and opens a real window. Unset plus
# WLR_BACKENDS=headless gives a virtual output nobody can see.
# pixman keeps it off the GPU, matching what the LiveISO's cage session does.
env -u WAYLAND_DISPLAY -u DISPLAY \
  WLR_BACKENDS=headless \
  WLR_RENDERER=pixman \
  WLR_LIBINPUT_NO_DEVICES=1 \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
  timeout "$DURATION" "$SWAY" -c "$SWAYCFG" > "$LOG" 2>&1
rc=$?

echo "--- headless session end (exit $rc; 124 means the timeout stopped it) ---"
echo "=== QML warnings and errors ==="
grep -Ei 'warn|error|fail|deprecat' "$LOG" \
  | grep -vi 'xkbcomp\|XKEYBOARD\|Could not resolve keysym\|Wayland connection broke' \
  || echo "(none)"
echo "=== configuration loaded? (1 = yes) ==="
grep -c 'Configuration Loaded' "$LOG"
[ -n "$SHOT" ] && [ -s "$SHOT" ] && echo "=== captured $(du -h "$SHOT" | cut -f1) to $SHOT ==="
rm -f "$SWAYCFG"
echo "full log kept at $LOG"
