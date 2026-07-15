#!/usr/bin/env bash
# ================================================================
#  tests/nix-smoke.sh — LiveISO boot oracle for the Nix target
#
#  Boots the flake's installer ISO (nix build .#iso) under OVMF + emulated
#  TPM2 (the same harness the Gentoo tiers use) and asserts the dots-installer
#  TUI reaches tty1: its unit echoes DOTS_TUI_READY to the serial console
#  (see nix/iso.nix).
#
#  Usage:  tests/nix-smoke.sh [path/to/tokyonight-dots-installer*.iso]
#          NIX_ISO=<path> tests/nix-smoke.sh
#          NIX_SMOKE_TIMEOUT=<s>   (default 600)
# ================================================================
set -euo pipefail
# vm.sh sources common.sh itself (whose path vars are readonly — don't source twice)
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/vm.sh"

VM_NAME="dots-nix-smoke"
TIMEOUT="${NIX_SMOKE_TIMEOUT:-600}"

section "nix-smoke: LiveISO boots to the installer TUI"
vm_check_host
require_cmds nix

iso="${1:-${NIX_ISO:-}}"
if [[ -z "${iso}" ]]; then
  log "building .#iso (no-op when cached)"
  nix build "${REPO_ROOT}#iso" -o "${ARTIFACTS}/result-iso"
  iso="$(compgen -G "${ARTIFACTS}/result-iso/iso/*.iso" | head -n1 || true)"
fi
[[ -n "${iso}" && -f "${iso}" ]] || die "installer ISO not found (${iso:-nix build produced nothing?})"
log "ISO: ${iso}"

disk="${ARTIFACTS}/${VM_NAME}.qcow2"
serial="${ARTIFACTS}/${VM_NAME}-serial.log"

vm_destroy "${VM_NAME}"
vm_make_disk "${disk}" 20G
vm_define "${VM_NAME}" 4096 4 "${disk}" "${iso}" "${serial}" "${REPO_ROOT}"
trap 'vm_destroy "${VM_NAME}"' EXIT
vm_start "${VM_NAME}"

log "waiting up to ${TIMEOUT}s for the TUI marker on serial…"
wait_for_marker "${serial}" "DOTS_TUI_READY" "${TIMEOUT}" \
  || die "DOTS_TUI_READY never appeared — see ${serial}"
assert_marker "${serial}" "DOTS_TUI_READY" "installer TUI reached tty1"
ok "nix-smoke passed"
