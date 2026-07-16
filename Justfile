# Justfile — task runner for tokyonight-dots (NixOS flake + LiveISO installer)
#
#   just            → list recipes
#   just nix-lint   → static checks: flake eval + installer-tui fmt/clippy/test
#   just iso        → build + Secure Boot-sign the LiveISO (the default)
#   just iso-full   → same, with both intel+amd system closures embedded
#   just iso-unsigned → plain unsigned LiveISO (no signing keys touched)
#   just nix-smoke  → boot the signed ISO under ENFORCING Secure Boot OVMF
#                     (+TPM2), assert the TUI comes up + SecureBoot=1;
#                     --no-secure-boot boots the unsigned ISO plainly
#   just setup      → install host prerequisites for the VM harness (uses sudo)
#   just clean      → remove all generated test artifacts
#
# Requires: `just`, `nix` (flakes enabled). nix-smoke additionally needs
# swtpm + libvirtd and membership in the libvirt/kvm groups — see `just setup`.

# Default: show the recipe list.
default:
    @just --list

# ── Nix target (flake + LiveISO installer) ───────────────────────
# Static gate: flake eval + installer-tui fmt/clippy/tests.
nix-lint:
    nix flake check
    cd installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test

# The MOK key is auto-generated into secrets/secureboot/ on the first run
# (shim + MOK chain); ./result-iso/iso/ keeps the raw unsigned nix output.
# Build + Secure Boot-sign the LiveISO — dd ./result-iso-signed/*.iso
iso:
    nix build .#iso -o result-iso
    ./scripts/sign-iso.sh result-iso/iso/*.iso

# Same, with both intel+amd system closures embedded (bigger ISO).
iso-full:
    nix build .#iso-full -o result-iso
    ./scripts/sign-iso.sh result-iso/iso/*.iso

# Plain unsigned LiveISO only (no Secure Boot; signing keys not touched).
iso-unsigned:
    nix build .#iso -o result-iso

# Deprecated alias — signing is the default now.
iso-signed: iso

# Asserts the TUI comes up AND the guest saw SecureBoot=1 (MS+MOK certs
# pre-enrolled in the NVRAM db); --no-secure-boot runs the plain unsigned ISO.
# Boot the signed ISO under Secure Boot-ENFORCING OVMF + swtpm.
nix-smoke *ARGS:
    ./tests/nix-smoke.sh {{ARGS}}

# Deprecated alias — Secure Boot is nix-smoke's default now.
nix-smoke-sb *ARGS:
    ./tests/nix-smoke.sh --secure-boot {{ARGS}}

# ── Host setup + housekeeping ────────────────────────────────────
# Install the host packages + services the nix-smoke VM harness needs (Arch host).
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing swtpm + xorriso (sudo pacman)…"
    sudo pacman -S --needed --noconfirm swtpm xorriso
    echo "Enabling libvirtd…"
    sudo systemctl enable --now libvirtd.socket
    echo "Starting + autostarting the default NAT network…"
    sudo virsh net-start default 2>/dev/null || true
    sudo virsh net-autostart default
    echo "Adding $USER to libvirt,kvm groups (re-login for it to take effect)…"
    sudo usermod -aG libvirt,kvm "$USER"
    echo "Done. Log out/in (or: newgrp libvirt) before running 'just nix-smoke'."

# Remove every generated/downloaded test artifact (safe — all gitignored).
clean:
    rm -rf tests/artifacts/*
    @echo "cleaned tests/artifacts/"
