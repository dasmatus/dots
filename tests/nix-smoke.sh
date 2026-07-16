#!/usr/bin/env bash
# ================================================================
#  tests/nix-smoke.sh — LiveISO boot oracle for the Nix target
#
#  DEFAULT: boots the SIGNED ISO (scripts/sign-iso.sh — a fresh .#iso
#  build or a given unsigned path is signed into artifacts/ first) under
#  the Secure Boot-ENFORCING OVMF build, with NVRAM pre-enrolled via
#  virt-fw-vars: Microsoft certs (validate the Fedora shim) + the ISO's own
#  MOK cert in db (validates our GRUB with no MokManager interaction — the
#  same db shape as `sbctl enroll-keys --microsoft` + this cert). Asserts
#  the dots-installer TUI reaches tty1 (DOTS_TUI_READY on the serial
#  console, see nix/iso.nix) AND that the guest kernel saw Secure Boot
#  enforced (DOTS_SECUREBOOT=1, its own reading of the SecureBoot efivar).
#
#  --no-secure-boot boots the plain unsigned ISO on the non-enforcing
#  OVMF instead (UEFI/TPM2 regression, no signing involved).
#
#  Usage:  tests/nix-smoke.sh [--no-secure-boot] [path/to/installer*.iso]
#          NIX_ISO=<path> tests/nix-smoke.sh
#          NIX_SMOKE_TIMEOUT=<s>   (default 600)
# ================================================================
set -euo pipefail
# vm.sh sources common.sh itself (whose path vars are readonly — don't source twice)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/vm.sh"

# Owner GUID recorded next to db entries we enroll (any fixed UUID works).
SB_OWNER_GUID="ce690aa3-f1e6-4a12-a8f3-8ea7add16fda"
TIMEOUT="${NIX_SMOKE_TIMEOUT:-600}"

SECURE_BOOT=1
iso=""
for arg in "$@"; do
  case "${arg}" in
    --secure-boot)    SECURE_BOOT=1 ;;
    --no-secure-boot) SECURE_BOOT=0 ;;
    -*)               die "unknown option: ${arg}" ;;
    *)                iso="${arg}" ;;
  esac
done
iso="${iso:-${NIX_ISO:-}}"

if (( SECURE_BOOT )); then
  VM_NAME="dots-nix-smoke-sb"
  section "nix-smoke: signed LiveISO boots under enforcing Secure Boot"
else
  VM_NAME="dots-nix-smoke"
  section "nix-smoke: LiveISO boots to the installer TUI"
fi
vm_check_host
require_cmds nix

if [[ -z "${iso}" ]]; then
  log "building .#iso (no-op when cached)"
  nix build "${REPO_ROOT}#iso" -o "${ARTIFACTS}/result-iso"
  iso="$(compgen -G "${ARTIFACTS}/result-iso/iso/*.iso" | head -n1 || true)"
fi
[[ -n "${iso}" && -f "${iso}" ]] || die "installer ISO not found (${iso:-nix build produced nothing?})"

disk="${ARTIFACTS}/${VM_NAME}.qcow2"
serial="${ARTIFACTS}/${VM_NAME}-serial.log"

vars_seed=""
if (( SECURE_BOOT )); then
  # The cert must come from the ISO itself — that both proves the ISO is
  # signed and keeps the test independent of where the private key lives.
  # An unsigned ISO (fresh .#iso build or a user-given path) is signed
  # into artifacts/ first; an already-signed one is booted as-is.
  cer="${ARTIFACTS}/${VM_NAME}-mok.cer"
  rm -f "${cer}"
  if ! xorriso -osirrox on -indev "${iso}" \
      -extract /EFI/BOOT/tokyonight-dots-mok.cer "${cer}" &>/dev/null; then
    log "unsigned ISO — signing it (scripts/sign-iso.sh)"
    signed="${ARTIFACTS}/$(basename "${iso}" .iso)-signed.iso"
    "${REPO_ROOT}/scripts/sign-iso.sh" -o "${signed}" "${iso}"
    iso="${signed}"
    xorriso -osirrox on -indev "${iso}" \
      -extract /EFI/BOOT/tokyonight-dots-mok.cer "${cer}" &>/dev/null \
      || die "no MOK cert in ${iso} even after signing — sign-iso.sh broken?"
  fi
  chmod u+w "${cer}"

  log "enrolling Secure Boot NVRAM (MS certs + ISO cert in db)"
  vars_seed="${ARTIFACTS}/${VM_NAME}-vars-seed.fd"
  vfv=(virt-fw-vars)
  command -v virt-fw-vars &>/dev/null \
    || vfv=(nix shell "${REPO_ROOT}#sb-tools" -c virt-fw-vars)
  "${vfv[@]}" --input "$(vm_ovmf_vars)" --output "${vars_seed}" \
    --enroll-redhat --secure-boot \
    --add-db "${SB_OWNER_GUID}" "${cer}" \
    >/dev/null || die "virt-fw-vars enrollment failed"
fi
log "ISO: ${iso}"

vm_destroy "${VM_NAME}"
vm_make_disk "${disk}" 20G
vm_define "${VM_NAME}" 4096 4 "${disk}" "${iso}" "${serial}" "${REPO_ROOT}" \
  "${SECURE_BOOT}" "${vars_seed}"
trap 'vm_destroy "${VM_NAME}"' EXIT
vm_start "${VM_NAME}"

log "waiting up to ${TIMEOUT}s for the TUI marker on serial…"
wait_for_marker "${serial}" "DOTS_TUI_READY" "${TIMEOUT}" \
  || die "DOTS_TUI_READY never appeared — see ${serial}"
assert_marker "${serial}" "DOTS_TUI_READY" "installer TUI reached tty1"
if (( SECURE_BOOT )); then
  assert_marker "${serial}" "DOTS_SECUREBOOT=1" "guest kernel sees SecureBoot=1"
  grep -Eq "Secure boot enabled|UEFI Secure Boot is enabled" "${serial}" \
    && ok "kernel dmesg confirms Secure Boot" \
    || warn "no Secure Boot dmesg line on serial (efivar marker already proves it)"
fi
ok "nix-smoke passed"
