# VM test harness

Layered tests for `install.sh` (the Gentoo FDE installer) and its full-systemd
immutable-`/usr` design. Run via the `Justfile` or `tests/run.sh` directly.

| Tier | Command | VM? | Time | What it proves |
|------|---------|-----|------|----------------|
| lint | `just lint`  | no  | secs | `install.sh` + harness scripts parse; YAML well-formed |
| smoke| `just smoke` | yes | mins | repart + TPM2 + DPS layout: 9-partition GPT, LUKS2 root with a `systemd-tpm2` token, btrfs subvols — stops at the `stage3` checkpoint |
| e2e  | `just e2e`   | yes | ~1h+ | full install + reboot: passphrase-free TPM2 unlock, read-only dm-verity `/usr`, first-boot reached |

## Prerequisites

`just lint` needs nothing but `bash` (optionally `shellcheck` + `python-pyyaml`).

The VM tiers need, on the **host**:

```
just setup          # installs swtpm + shellcheck, enables libvirtd, adds you to libvirt/kvm
# then log out/in (group change) or:  newgrp libvirt
sudo virsh net-start default && sudo virsh net-autostart default   # NAT for the guest
```

Already required and present on a typical Arch host: `/dev/kvm` (+ nested virt if
the host is itself a VM), `edk2-ovmf` (OVMF firmware), `libvirt`, `qemu`,
`xorriso`, `curl`.

## How it works

- **Boot**: the VM boots the **SystemRescue** live ISO through **OVMF/UEFI** (genuine
  UEFI — `install.sh` aborts without `/sys/firmware/efi`) with an **emulated TPM 2.0**
  via **swtpm**. The ISO is remastered once (`tests/lib/vm.sh`) to add `console=ttyS0`
  and a SystemRescue **autorun** hook.
- **Driving**: `tests/guest/autorun` mounts the repo working tree (shared into the guest
  over **9p**, tag `dotsrepo`) and runs `tests/guest/run.sh`, which exports the
  `AFOSI_DRIVEN` env contract (`disk=/dev/vda wipe_confirm=true …`) plus the test knobs
  (`INSTALL_STOP_AFTER`, `TPM2_PCRS=`) and executes the **local** `install.sh`. Because
  the *working tree* is shared, tests exercise **uncommitted** changes.
- **Observing**: the guest writes machine-parseable markers to `ttyS0` → the host serial
  log (`tests/artifacts/<name>.serial.log`), and dumps the on-disk layout to
  `tests/artifacts/guest-out/layout.txt`. The host asserts on both.
- **TPM2 in tests**: the VM enrols with **`TPM2_PCRS=` (empty)** to avoid swtpm/OVMF PCR
  fragility; production binds PCR 7 (see the plan / `CLAUDE.md`).

## Layout

```
tests/
  run.sh            dispatcher: lint | smoke | e2e
  lint.sh           Tier 0
  smoke.sh          Tier 1
  e2e.sh            Tier 2
  lib/
    common.sh       logging, paths, serial-log assert helpers
    vm.sh           libvirt/OVMF/swtpm/ISO-remaster lifecycle
    domain.xml.tmpl libvirt domain (OVMF + TPM2 + serial + 9p)
  guest/
    autorun         SystemRescue autorun → mounts 9p, runs run.sh
    run.sh          in-guest driver of install.sh + layout capture
  artifacts/        ALL generated junk (gitignored): qcow2, ISOs, OVMF vars,
                    swtpm state, serial logs, captured output
```

Everything under `artifacts/` is gitignored; only the scripts and the XML
template are tracked.
