#!/usr/bin/env bash
# ================================================================
#  tests/lib/common.sh — shared helpers for the VM test harness
#
#  Sourced by tests/run.sh and the per-tier scripts. Provides:
#    · colour/log helpers (log/ok/warn/die/section)
#    · path constants (REPO_ROOT, ARTIFACTS, ISO_CACHE)
#    · serial-log wait/assert helpers
#    · a dependency checker
#
#  No side effects on source beyond setting readonly vars.
# ================================================================
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────
# This file lives in tests/lib/ ; REPO_ROOT is two levels up.
_COMMON_SH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${_COMMON_SH_DIR}/../.." &>/dev/null && pwd)"
TESTS_DIR="${REPO_ROOT}/tests"
# All generated / downloaded junk lives here and is gitignored.
ARTIFACTS="${TESTS_DIR}/artifacts"
ISO_CACHE="${ARTIFACTS}/iso"
readonly _COMMON_SH_DIR REPO_ROOT TESTS_DIR ARTIFACTS ISO_CACHE

mkdir -p "${ARTIFACTS}" "${ISO_CACHE}"

# ── Colours + logging ────────────────────────────────────────────
if [[ -t 1 ]]; then
  _RED=$'\033[0;31m' _GRN=$'\033[0;32m' _YLW=$'\033[0;33m'
  _CYN=$'\033[0;36m' _BLD=$'\033[1m'    _RST=$'\033[0m'
else
  _RED='' _GRN='' _YLW='' _CYN='' _BLD='' _RST=''
fi

log()     { printf '%s[+]%s %s\n'      "${_GRN}" "${_RST}" "$*"; }
ok()      { printf '%s[✓]%s %s\n'      "${_GRN}" "${_RST}" "$*"; }
warn()    { printf '%s[!]%s %s\n'      "${_YLW}" "${_RST}" "$*" >&2; }
die()     { printf '%s[✗]%s %s\n'      "${_RED}" "${_RST}" "$*" >&2; exit 1; }
section() { printf '\n%s%s━━ %s%s\n'   "${_CYN}" "${_BLD}" "$*" "${_RST}"; }

# ── Dependency checker ───────────────────────────────────────────
# require_cmds virsh qemu-img swtpm ...  → die with a helpful message if missing.
require_cmds() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "${c}" &>/dev/null || missing+=("${c}")
  done
  if (( ${#missing[@]} )); then
    die "missing required commands: ${missing[*]}
  install them and re-run (see tests/README.md → Prerequisites)"
  fi
}

# ── Serial-log assertions ────────────────────────────────────────
# wait_for_marker <logfile> <regex> <timeout_s>
#   Polls a growing serial log until <regex> appears, or fails after timeout.
wait_for_marker() {
  local logfile="$1" regex="$2" timeout="${3:-600}"
  local waited=0
  while (( waited < timeout )); do
    if [[ -f "${logfile}" ]] && grep -Eq -- "${regex}" "${logfile}"; then
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  return 1
}

# assert_marker <logfile> <regex> <human description>
assert_marker() {
  local logfile="$1" regex="$2" desc="$3"
  if grep -Eq -- "${regex}" "${logfile}" 2>/dev/null; then
    ok "${desc}"
  else
    die "assertion FAILED: ${desc}  (no /${regex}/ in ${logfile})"
  fi
}
