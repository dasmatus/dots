# VM test harness

A single boot oracle for the Nix target: builds + signs the flake's LiveISO
(`nix build .#iso` → `scripts/sign-iso.sh`) and boots it under Secure
Boot-**enforcing** OVMF (genuine UEFI) with an emulated TPM 2.0 (swtpm),
asserting the `dots-installer` TUI reaches tty1 with Secure Boot verified
enabled. Run via `just nix-smoke` or `tests/nix-smoke.sh` directly;
`--no-secure-boot` gives the plain unsigned regression run.

| Command | VM? | Time | What it proves |
|---------|-----|------|----------------|
| `just nix-lint`  | no  | secs | `nix flake check` + installer-tui `cargo fmt/clippy/test` |
| `just nix-smoke` | yes | mins | **default**: the signed ISO boots under Secure Boot-**enforcing** OVMF: NVRAM is pre-enrolled via `virt-fw-vars` (Microsoft certs validate the Fedora shim, the ISO's MOK cert in db validates our GRUB), TPM2 attaches, and the guest must report both `DOTS_TUI_READY` and `DOTS_SECUREBOOT=1` on the serial console |
| `just nix-smoke --no-secure-boot` | yes | mins | the plain unsigned LiveISO boots to UEFI (non-enforcing OVMF), TPM2 attaches, the installer TUI reaches tty1 (`DOTS_TUI_READY`) |

## Prerequisites

The VM harness needs, on the **host**:

```
just setup          # installs swtpm + xorriso, enables libvirtd, adds you to libvirt/kvm
# then log out/in (group change) or:  newgrp libvirt
sudo virsh net-start default && sudo virsh net-autostart default   # NAT for the guest
```

Already required and present on a typical Arch host: `/dev/kvm` (+ nested virt
if the host is itself a VM), `edk2-ovmf` (OVMF firmware), `libvirt`, `qemu`,
`xorriso`, `nix` (flakes enabled).

## How it works

- **Boot**: `tests/nix-smoke.sh` builds (or reuses) `.#iso`, signs it via
  `scripts/sign-iso.sh` (default mode; skipped with `--no-secure-boot`),
  then `tests/lib/vm.sh` defines and starts a libvirt domain
  (`tests/lib/domain.xml.tmpl`) through **OVMF/UEFI** with an **emulated
  TPM 2.0** via **swtpm**, using `qemu:///session` so the serial log and
  disk stay owned by the invoking user (no root, no libvirt group, no
  security-driver relabel).
- **Observing**: the guest's serial console is captured to
  `tests/artifacts/<name>-serial.log`. The harness polls that log for the
  `DOTS_TUI_READY` marker the installer's systemd unit echoes once it reaches
  tty1 (see `nix/iso.nix`), and fails after `NIX_SMOKE_TIMEOUT` (default
  600s).

## Layout

```
tests/
  nix-smoke.sh      LiveISO boot oracle — the only entry point
                    (default: signs the ISO and boots it under enforcing
                    Secure Boot OVMF with pre-enrolled NVRAM;
                    --no-secure-boot for the plain unsigned run)
  lib/
    common.sh        logging, paths, serial-log wait/assert helpers
    vm.sh             libvirt/OVMF/swtpm VM lifecycle (check/disk/define/start/destroy)
    domain.xml.tmpl   libvirt domain template (OVMF + TPM2 + serial + 9p)
  artifacts/          ALL generated junk (gitignored): qcow2, ISOs (incl. the
                      signed one), OVMF vars + enrolled seeds, swtpm state,
                      serial logs, extracted MOK certs
```

Everything under `artifacts/` is gitignored; only the scripts and the XML
template are tracked.
