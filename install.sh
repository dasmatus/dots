#!/usr/bin/env bash
# ================================================================
#  NixOS installer bootstrap — builds and runs the dots-installer
#  TUI via nix. See rust/installer-tui/ for the actual installer source
#  (ratatui frontend driving disko + nixos-install).
#
#  Usage:
#    curl -fsSL https://codeberg.org/dasmatus/dots/raw/branch/main/install.sh | bash
# ================================================================
set -euo pipefail

# nix has no `codeberg:` shorthand scheme, so use the generic git+https
# flake URL (resolves the default branch). The repo is public, so this
# anonymous fetch needs no credentials.
REMOTE_FLAKE="git+https://codeberg.org/dasmatus/dots"

die() { printf '\033[0;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

command -v nix &>/dev/null \
  || die "nix required — install it from https://nixos.org/download"

# repo checkout / 9p share / LiveISO (/etc/dots) all keep flake.nix next to
# this script; anywhere else, fall back to /etc/dots, then the remote flake.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-.}")" &>/dev/null && pwd -P)

if [[ -f "${SELF_DIR}/flake.nix" ]]; then
  FLAKE="${SELF_DIR}"
elif [[ -f /etc/dots/flake.nix ]]; then
  FLAKE="/etc/dots"
else
  FLAKE="${REMOTE_FLAKE}"
fi

exec nix --extra-experimental-features 'nix-command flakes' run "${FLAKE}#dots-installer"
