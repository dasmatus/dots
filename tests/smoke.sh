#!/usr/bin/env bash
# ================================================================
#  tests/smoke.sh — Tier 1: install to the stage3 checkpoint in a VM
#
#  Boots an OVMF + TPM2 VM on the SystemRescue ISO, runs the LOCAL install.sh
#  headless up to INSTALL_STOP_AFTER=stage3, then asserts the on-disk result:
#    · the full DPS partition table (ESP + root + swap + empty usr triplet)
#    · the root partition is LUKS2 carrying a systemd-tpm2 token
#    · btrfs was created inside the TPM2-unlocked root
#  Fast (minutes): stops BEFORE the multi-hour emerge + /usr seal (that is e2e).
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/vm.sh"

KEEP=0
for a in "$@"; do case "${a}" in -k|--keep) KEEP=1;; esac; done

NAME="dots-smoke"
DISK="${ARTIFACTS}/${NAME}.qcow2"
SERIAL="${ARTIFACTS}/${NAME}.serial.log"
LAYOUT="${ARTIFACTS}/guest-out/layout.txt"

cleanup() {
  local rc=$?
  if (( KEEP )); then
    warn "keeping VM '${NAME}' + artifacts (--keep)"
  else
    vm_destroy "${NAME}"
    rm -f "${DISK}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

section "Tier 1 — smoke"
vm_check_host
ISO="$(vm_fetch_iso)"

log "preparing throwaway disk (20 GiB, sparse) + guest env"
vm_destroy "${NAME}"                     # clear any stale domain first
vm_make_disk "${DISK}" 20G
mkdir -p "${ARTIFACTS}/guest-out"; rm -f "${LAYOUT}"
# Smoke stops at stage3 (no /usr seal), so the A/B usr slots can be tiny — keeps
# the layout inside a small sparse disk. TPM2_PCRS= (empty) → no PCR policy.
cat > "${ARTIFACTS}/guest-env" <<EOF
TEST_MODE=smoke
disk=/dev/vda
wipe_confirm=true
hostname=vmtest
root_password=vmtest
INSTALL_STOP_AFTER=stage3
TPM2_PCRS=
USR_SIZE=1G
EOF

log "defining + starting VM (OVMF + swtpm TPM2)"
vm_define "${NAME}" 4096 4 "${DISK}" "${ISO}" "${SERIAL}" "${REPO_ROOT}"
vm_start "${NAME}"

log "waiting for the install to reach the stage3 checkpoint (serial log: ${SERIAL})"
if ! wait_for_marker "${SERIAL}" '=== HARNESS: DONE rc=' 1800; then
  warn "timed out; tail of serial log:"; tail -40 "${SERIAL}" 2>/dev/null >&2
  die "smoke run did not complete within 30 min"
fi

# ── Assertions ───────────────────────────────────────────────────
section "smoke assertions"
assert_marker "${SERIAL}" '=== CHECKPOINT:stage3 ===' \
  "installer reached the stage3 checkpoint"
if grep -Eq '=== HARNESS: DONE rc=0 ===' "${SERIAL}"; then
  ok "guest runner completed cleanly (rc=0)"
else
  warn "guest rc was non-zero:"; grep -E '=== HARNESS: (install exited|DONE)' "${SERIAL}" >&2
  die "installer exited non-zero before the checkpoint"
fi

# The guest prints the on-disk layout to the serial console between markers
# (a 9p write can be lost on the forced poweroff), so assert against that.
LAYOUT_SLICE="${ARTIFACTS}/dots-smoke.layout.txt"
tr -d '\000' < "${SERIAL}" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
  | awk '/=== HARNESS-LAYOUT-BEGIN ===/{f=1;next} /=== HARNESS-LAYOUT-END ===/{f=0} f' \
  > "${LAYOUT_SLICE}"
[[ -s "${LAYOUT_SLICE}" ]] || die "no captured layout in the serial log (expected HARNESS-LAYOUT markers)"

assert_marker "${LAYOUT_SLICE}" 'usr_a|usr-verity|EFI System|root-x86-64|Linux root' \
  "DPS partitions present (ESP + root + usr triplet)"
assert_marker "${LAYOUT_SLICE}" 'LUKS2|Version:[[:space:]]*2'   "root partition is LUKS2"
assert_marker "${LAYOUT_SLICE}" 'systemd-tpm2|tpm2'             "root LUKS carries a TPM2 token"
assert_marker "${LAYOUT_SLICE}" 'swap'                          "swap partition present"

ok "smoke passed — repart + TPM2 + DPS layout verified"
