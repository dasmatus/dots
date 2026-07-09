#!/usr/bin/env bash
# ================================================================
#  Gentoo automated FDE installer — curl wrapper
#
#  The real installer is the Python package in installer/ (full-systemd,
#  immutable-/usr Gentoo — see installer/main.py for the layout summary).
#  This wrapper only locates or fetches that package and hands off to it:
#
#    · repo checkout / VM 9p share → run installer/ next to this script
#    · `curl … | bash`             → fetch installer/ to /root/installer first
#
#  Usage:
#    curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
#
#  Re-entry contract (unchanged): afosi's final action runs
#  `bash /root/install.sh` with AFOSI_DRIVEN=1 + the answers in the env, and
#  the VM test harness runs `bash <repo>/install.sh` the same way. All env
#  knobs (disk, wipe_confirm, hostname, root_password, TPM2_PCRS, USR_SIZE,
#  STAGE3_BASE, INSTALL_STOP_AFTER) pass through untouched.
# ================================================================
set -euo pipefail

DOTS_RAW="https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main"

# Keep in sync with the modules in installer/ (lint.sh cross-checks this list).
PKG_FILES=(
  __init__.py
  main.py
  common.py
  config.py
  bootstrap.py
  preflight.py
  partition.py
  stage3.py
  hostconfig.py
  chroot_base.py
  chroot_boot.py
  chroot_system.py
  chroot_sysupdate.py
  seal.py
)

die() { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Must run as root"
command -v python3 &>/dev/null \
  || die "python3 required in the live env (present on SystemRescue / Gentoo LiveGUI / Arch)"

# When piped (`curl | bash`) BASH_SOURCE is unset → fall back to the cwd; the
# local-package check then simply fails and we fetch.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" &>/dev/null && pwd -P)

if [[ -f "${SELF_DIR}/installer/main.py" ]]; then
  PKG_DIR="${SELF_DIR}/installer"
else
  command -v curl &>/dev/null || die "curl required to fetch the installer"
  PKG_DIR="/root/installer"
  printf '\033[0;32m[+]\033[0m Fetching installer package to %s…\n' "${PKG_DIR}"
  mkdir -p "${PKG_DIR}"
  for f in "${PKG_FILES[@]}"; do
    curl -fsSL "${DOTS_RAW}/installer/${f}" -o "${PKG_DIR}/${f}" \
      || die "fetch failed: installer/${f}"
  done
fi

# Unbuffered: checkpoint/progress markers must stream to the serial console
# (the VM test harness greps them live).
exec env PYTHONUNBUFFERED=1 python3 "${PKG_DIR}/main.py" "$@"
