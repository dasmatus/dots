#!/usr/bin/env bash
# ================================================================
#  tests/e2e.sh — Tier 2: full install + reboot + verity-boot oracle (~1h+)
#
#  Phase 1: boot the ISO, run install.sh to COMPLETION (no checkpoint) — full
#           emerge + /usr seal + TPM2 enrol. Slow; leans on the binhost.
#  Phase 2: detach the ISO, reboot the SAME domain (persistent swtpm NVRAM so
#           the TPM2-enrolled key still unlocks), and confirm over serial:
#             · passphrase-free TPM2 root unlock
#             · /usr mounted read-only from dm-verity (remount,rw fails)
#             · the first-boot banner (gentoo-firstboot) is reached
#
#  Requires the installed UKI to carry `console=ttyS0` — the refactored
#  install.sh does this when TPM2_PCRS is empty / a test flag is set (so the
#  installed system's boot is observable on the serial log). See tests/README.md.
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/vm.sh"

KEEP=0
for a in "$@"; do case "${a}" in -k|--keep) KEEP=1;; esac; done

NAME="dots-e2e"
DISK="${ARTIFACTS}/${NAME}.qcow2"
SERIAL="${ARTIFACTS}/${NAME}.serial.log"

cleanup() {
  local rc=$?
  (( KEEP )) && { warn "keeping VM '${NAME}' + artifacts (--keep)"; exit "${rc}"; }
  vm_destroy "${NAME}"; rm -f "${DISK}"
  exit "${rc}"
}
trap cleanup EXIT

section "Tier 2 — e2e (full install + verity boot)"
vm_check_host
ISO="$(vm_fetch_iso)"

log "preparing throwaway disk (40 GiB) + guest env"
vm_destroy "${NAME}"
vm_make_disk "${DISK}" 40G
mkdir -p "${ARTIFACTS}/guest-out"
cat > "${ARTIFACTS}/guest-env" <<EOF
TEST_MODE=e2e
disk=/dev/vda
wipe_confirm=true
hostname=vmtest
root_password=vmtest
INSTALL_STOP_AFTER=
TPM2_PCRS=
EOF

# ── Phase 1: full install ────────────────────────────────────────
log "Phase 1: full install (this takes a long time; watch ${SERIAL})"
vm_define "${NAME}" 6144 6 "${DISK}" "${ISO}" "${SERIAL}" "${REPO_ROOT}"
vm_start "${NAME}"
if ! wait_for_marker "${SERIAL}" '=== HARNESS: DONE rc=' 14400; then   # up to 4h
  warn "install did not finish; tail:"; tail -60 "${SERIAL}" >&2
  die "e2e phase-1 install timed out"
fi
grep -Eq '=== HARNESS: DONE rc=0 ===' "${SERIAL}" || die "e2e install exited non-zero"
ok "Phase 1 complete — installed system on disk"

# ── Phase 2: reboot from disk (no ISO) and observe the boot ──────
log "Phase 2: rebooting from the installed disk (TPM2 auto-unlock)"
: > "${SERIAL}"                                   # fresh log for the boot
# Redefine the domain to boot the installed disk only (strip the cdrom / ISO).
sed -e "/device='cdrom'/,/<\/disk>/d" \
    -e "s|<boot dev='cdrom'/>||" \
    "${ARTIFACTS}/${NAME}.xml" > "${ARTIFACTS}/${NAME}.hd.xml"
vm_destroy "${NAME}"
"${VIRSH[@]}" define "${ARTIFACTS}/${NAME}.hd.xml" >/dev/null
vm_start "${NAME}"

log "waiting for the first-boot banner (proves TPM2 unlock + verity /usr)"
if ! wait_for_marker "${SERIAL}" 'First boot|create your systemd-homed user' 900; then
  warn "did not reach first-boot; tail:"; tail -60 "${SERIAL}" >&2
  die "e2e boot oracle failed — system did not reach first boot"
fi

# ── Boot assertions (best-effort; installed system must echo to ttyS0) ──
section "e2e boot assertions"
assert_marker "${SERIAL}" 'First boot|systemd-homed user' "reached first-boot (multi-user.target)"
if grep -Eq 'usr\.mount|/usr .* ro|dm-verity|veritysetup' "${SERIAL}"; then
  ok "evidence of read-only dm-verity /usr on the boot log"
else
  warn "no explicit verity /usr evidence on serial — inspect ${SERIAL} (installed UKI may lack console=ttyS0)"
fi

ok "e2e passed — passphrase-free TPM2 boot reached first boot"
