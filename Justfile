# Justfile — task runner for tokyonight-dots
#
#   just            → list recipes
#   just lint       → static checks (bash -n, shellcheck, YAML), no VM
#   just smoke      → VM install to the stage3 checkpoint + layout assertions
#   just e2e        → full install + reboot + verity-boot assertions (~1h+)
#   just test       → lint + smoke
#   just setup      → install host prerequisites for the VM harness (uses sudo)
#   just clean      → remove all generated test artifacts
#
# Requires: `just` (dev-util/just). VM tiers additionally need swtpm + libvirtd
# and membership in the libvirt/kvm groups — see `just setup`.

# Default: show the recipe list.
default:
    @just --list

# ── Test tiers ───────────────────────────────────────────────────
# Tier 0: static checks only — no VM, no root.
lint:
    ./tests/run.sh lint

# Tier 1: spin up an OVMF+TPM2 VM, install to the stage3 checkpoint, assert layout.
smoke *ARGS:
    ./tests/run.sh smoke {{ARGS}}

# Tier 2: full install + reboot + read-only dm-verity /usr assertions.
e2e *ARGS:
    ./tests/run.sh e2e {{ARGS}}

# Lint + smoke (the everyday gate).
test: lint smoke

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
# Install the host packages + services the VM harness needs (Arch host).
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing swtpm + shellcheck + xorriso (sudo pacman)…"
    sudo pacman -S --needed --noconfirm swtpm shellcheck xorriso
    echo "Enabling libvirtd…"
    sudo systemctl enable --now libvirtd.socket
    echo "Starting + autostarting the default NAT network…"
    sudo virsh net-start default 2>/dev/null || true
    sudo virsh net-autostart default
    echo "Adding $USER to libvirt,kvm groups (re-login for it to take effect)…"
    sudo usermod -aG libvirt,kvm "$USER"
    echo "Done. Log out/in (or: newgrp libvirt) before running 'just smoke'."

# Remove every generated/downloaded test artifact (safe — all gitignored).
clean:
    rm -rf tests/artifacts/*
    @echo "cleaned tests/artifacts/"
