#!/usr/bin/env bash
# ================================================================
#  tests/guest/run.sh — runs INSIDE the SystemRescue guest
#
#  Sourced params come from tests/artifacts/guest-env, written by the host
#  driver before boot. Drives the LOCAL (9p-shared) install.sh headlessly via
#  the AFOSI_DRIVEN env contract, captures the resulting on-disk layout for
#  host-side assertions, then powers off so the host knows the run is done.
#
#  Emits machine-parseable markers on stdout (→ ttyS0 → host serial log):
#    === HARNESS: install start ===
#    === CHECKPOINT:<stage> ===        (from install.sh's own hook)
#    === HARNESS: install exited rc=N ===
#    === HARNESS: DONE rc=N ===
# ================================================================
set -uo pipefail
REPO=/mnt/dotsrepo
ENVFILE="${REPO}/tests/artifacts/guest-env"
OUT="${REPO}/tests/artifacts/guest-out"
mkdir -p "${OUT}"

poweroff_now() { sync; systemctl poweroff -f 2>/dev/null || poweroff -f 2>/dev/null || halt -f; }

if [[ ! -f "${ENVFILE}" ]]; then
  echo "=== HARNESS: FAIL no-guest-env ==="
  echo "=== HARNESS: DONE rc=91 ==="
  poweroff_now; exit 0
fi
# shellcheck disable=SC1090
. "${ENVFILE}"

# The AFOSI second-pass contract (install.sh reads these from the environment).
export AFOSI_DRIVEN=1
export disk="${disk:?}" wipe_confirm="${wipe_confirm:?}"
export hostname="${hostname:-vmtest}" root_password="${root_password:-vmtest}"
# Harness/test knobs consumed by the refactored install.sh.
export INSTALL_STOP_AFTER="${INSTALL_STOP_AFTER:-}"
export TPM2_PCRS="${TPM2_PCRS:-}"
export USR_SIZE="${USR_SIZE:-8G}"

echo "=== HARNESS: install start (mode=${TEST_MODE:-?} stop=${INSTALL_STOP_AFTER:-none}) ==="
bash "${REPO}/install.sh"
rc=$?
echo "=== HARNESS: install exited rc=${rc} ==="

# Capture the on-disk result to the SERIAL console (host reads it reliably from
# the serial log — a 9p write can be lost when the forced poweroff tears down the
# mount). Wrapped in markers so the host can slice it out. Also mirror to the 9p
# share best-effort.
echo "=== HARNESS-LAYOUT-BEGIN ==="
{
  echo "### sgdisk -p ${disk}";                     sgdisk -p "${disk}" 2>&1
  echo "### lsblk";                                 lsblk -o NAME,TYPE,FSTYPE,PARTLABEL,SIZE "${disk}" 2>&1
  echo "### blkid";                                 blkid 2>&1
  echo "### cryptsetup luksDump by-partlabel/root"; cryptsetup luksDump /dev/disk/by-partlabel/root 2>&1
  echo "### systemd-cryptenroll by-partlabel/root"; systemd-cryptenroll /dev/disk/by-partlabel/root 2>&1
  echo "### mounts";                                { mount | grep -aE 'btrfs|cryptroot|mapper' ; } 2>&1
} | tee "${OUT}/layout.txt" 2>/dev/null
echo "=== HARNESS-LAYOUT-END ==="
sync

echo "=== HARNESS: DONE rc=${rc} ==="
poweroff_now
