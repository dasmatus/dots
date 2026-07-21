# Justfile — task runner for tokyonight-dots (NixOS flake + LiveISO installer)
#
#   just            → list recipes
#   just nix-lint   → static checks: flake eval + installer-tui fmt/clippy/test
#   just iso        → build + Secure Boot-sign the LiveISO (the default)
#   just iso-full   → same, with both intel+amd system closures embedded
#   just iso-unsigned → plain unsigned LiveISO (no signing keys touched)
#   just nix-smoke  → NixOS VM test: boot the signed ISO under ENFORCING
#                     Secure Boot OVMF (+TPM2), assert the TUI comes up +
#                     SecureBoot=1; --no-secure-boot boots the unsigned ISO
#   just clean      → remove local build/test leftovers
#
# Requires: `just`, `nix` (flakes enabled). nix-smoke additionally needs
# /dev/kvm (without it QEMU falls back to slow TCG emulation). No libvirt,
# swtpm, or OVMF host packages — the NixOS test framework brings its own.

# Default: show the recipe list.
default:
    @just --list

# ── Nix target (flake + LiveISO installer) ───────────────────────
# Nothing is built here — the VM-test checks are built by nix-smoke instead.
# Static gate: flake eval (--no-build) + installer-tui fmt/clippy/tests.
nix-lint:
    nix flake check --no-build
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

# Build + sign, and additionally cosign GRUB + kernels with your local
# sbctl db key (the one lanzaboote signs your systems with). Machines that
# trust that key in their Secure Boot db boot with NO MokManager prompt;
# others still enroll the MOK once. Reads the root-owned key via sudo.
iso-cosign:
    nix build .#iso -o result-iso
    ./scripts/sign-iso.sh --sbctl result-iso/iso/*.iso

# Deprecated alias — signing is the default now.
iso-signed: iso

# NixOS test framework boot oracle (tests/default.nix): signs the ISO with an
# ephemeral in-sandbox MOK, pre-enrolls NVRAM (MS certs + that MOK in db) and
# asserts DOTS_TUI_READY + DOTS_SECUREBOOT=1 on the serial console;
# --no-secure-boot runs the plain unsigned check (DOTS_TUI_READY only).
# Boot the signed ISO under Secure Boot-ENFORCING OVMF + TPM2 (NixOS VM test).
nix-smoke *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    check=iso-secureboot
    for a in {{ ARGS }}; do
        [ "$a" = --no-secure-boot ] && check=iso-boot
    done
    nix build -L ".#checks.x86_64-linux.$check"

# start_all() / machine.wait_for_console_text("DOTS_TUI_READY") / etc.;
# for the plain variant use .#checks.x86_64-linux.iso-boot.driverInteractive.
# Debug the Secure Boot VM test in the driver's interactive Python REPL.
nix-smoke-interactive:
    nix run .#checks.x86_64-linux.iso-secureboot.driverInteractive

# ── FIDO2 ──────────────────────────────────────────────────────────
# Enroll a FIDO2/U2F key as a MANDATORY second factor for hyprlock, the ly
# display manager, and console login (2FA: key + password — both required).
# Run once PER KEY — tap the key when prompted. Each run appends one line to
# ~/.config/Yubico/u2f_keys (two keys = two runs = two lines). After enrolling,
# lock (hyprlock) or log out: TAP THE KEY FIRST, then type your password and
# press Enter — both are required. NB: hyprlock shows "Password:" even during
# the touch phase (hyprlock issue #723), so just tap when the screen is up.
# Requires the pkgs.pam_u2f (pamu2fcfg) added in nix/modules/desktop.nix.
enroll-fido:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ~/.config/Yubico
    touch ~/.config/Yubico/u2f_keys
    chmod 600 ~/.config/Yubico/u2f_keys
    pamu2fcfg >> ~/.config/Yubico/u2f_keys
    echo "Key enrolled ($(wc -l < ~/.config/Yubico/u2f_keys) key(s) total). Run again for each extra key."

# ── Housekeeping ─────────────────────────────────────────────────
# Remove local build/test leftovers (safe — all gitignored).
clean:
    rm -rf result result-* *.qcow2 vm-state-*
    @echo "cleaned build + VM-test leftovers"
