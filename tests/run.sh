#!/usr/bin/env bash
# ================================================================
#  tests/run.sh — VM test harness dispatcher
#
#    tests/run.sh lint    → Tier 0, static checks, no VM (seconds)
#    tests/run.sh smoke   → Tier 1, install to a checkpoint in a VM (minutes)
#    tests/run.sh e2e     → Tier 2, full install + reboot + verity-boot (~1h+)
#
#  See tests/README.md for prerequisites (swtpm, libvirtd, group membership).
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Usage: tests/run.sh <tier> [options]

Tiers:
  lint    static checks only (bash -n, shellcheck, YAML) — no VM, no root
  smoke   spin up an OVMF+TPM2 VM, run install.sh to the stage3 checkpoint,
          assert the partition/crypto/verity layout, tear down
  e2e     full install + reboot; assert passphrase-free TPM2 boot and a
          read-only dm-verity /usr

Options:
  -k, --keep     keep the VM + artifacts on exit (default: destroy)
  -h, --help     this help
EOF
}

tier="${1:-}"; shift || true
case "${tier}" in
  lint)  exec "${TESTS_DIR}/lint.sh"  "$@" ;;
  smoke) exec "${TESTS_DIR}/smoke.sh" "$@" ;;
  e2e)   exec "${TESTS_DIR}/e2e.sh"   "$@" ;;
  -h|--help|"") usage; [[ -z "${tier}" ]] && exit 1 || exit 0 ;;
  *) usage; die "unknown tier: ${tier}" ;;
esac
