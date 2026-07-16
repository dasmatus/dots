# Justfile — task runner for tokyonight-dots (NixOS flake + LiveISO installer)
#
#   just            → list recipes
#   just nix-lint   → static checks: flake eval + installer-tui fmt/clippy/test
#   just iso        → build the LiveISO (lean; installer auto-starts on tty1)
#   just iso-full   → same, with both intel+amd system closures embedded
#   just nix-smoke  → boot the ISO in an OVMF+TPM2 VM, assert the TUI comes up
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

# Build the LiveISO (installer auto-starts on tty1). Result: ./result-iso/iso/
iso:
    nix build .#iso -o result-iso

# Same, with both intel+amd system closures embedded (bigger ISO).
iso-full:
    nix build .#iso-full -o result-iso

# Boot the built ISO in the OVMF+swtpm harness, assert the TUI comes up.
nix-smoke *ARGS:
    ./tests/nix-smoke.sh {{ARGS}}

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
