# VM tests — NixOS test framework

The LiveISO boot oracle is a flake check built on
[`pkgs.testers.runNixOSTest`](https://nixos.org/manual/nixos/unstable/#sec-nixos-tests):
a hermetic `nix build` that boots the (plain, unsigned) ISO under OVMF +
swtpm — no libvirt, no host packages, no root. Defined in
[`default.nix`](default.nix), wired into `checks.x86_64-linux` in the flake.

| Check | What it proves |
|-------|----------------|
| `iso-boot` | the LiveISO (`.#iso`) boots through plain OVMF UEFI with an emulated TPM 2.0 and the `dots-installer` TUI reaches tty1 — `DOTS_TUI_READY` on the serial console |
| `userborn-reboot-login` | under userborn + immutable `/etc`, the yescrypt hash in the persisted shadow survives a cold restart (login still works after reboot) |

Also in `checks`: `nix-lint`-fast eval checks (`settings-eval`,
`facter-*-eval`) and the `dots-installer` package build — see `flake.nix`.

## Running

```
nix run .#nix-smoke                    # = nix build -L .#checks.x86_64-linux.iso-boot
nix run .#nix-smoke-interactive        # test driver Python REPL (see below)
```

Prerequisites: `nix` (flakes) and `/dev/kvm`. Without KVM, QEMU falls back
to TCG software emulation — works, but takes ages (that's what CI does).

The built check (`result/`) contains the test driver log and the full
serial transcript.

## Debugging

`nix run .#nix-smoke-interactive` drops you into the driver's Python REPL
with the boot VM defined
(`nix run .#checks.x86_64-linux.iso-boot.driverInteractive`):

```python
>>> machine.start()
>>> machine.wait_for_console_text("DOTS_TUI_READY")
```

The booted ISO has **no test instrumentation** (no backdoor shell), so
assertions are console-only — `wait_for_console_text`, not
`wait_for_unit`/`succeed`. The interactive driver leaves `*.qcow2` /
`vm-state-*` behind in the cwd; `nix run .#clean` removes them.

## How it works (`default.nix`)

- **Boot** (`iso-boot`): `virtualisation.directBoot.enable = false` +
  `useEFIBoot` boot real OVMF firmware instead of the test driver's default
  `-kernel` shortcut; the ISO is attached as an IDE CD with `bootindex=0`
  (the blank 20 G root disk — a stand-in install target — carries
  `bootindex=1`). A swtpm TPM 2.0 is attached via `virtualisation.tpm.enable`
  — the installed system unlocks the LUKS root via a TPM2 token on PCR 7, so
  the chip the boot chain needs is emulated.
- **`userborn-reboot-login`** is a separate `runNixOSTest` (not ISO-based):
  it boots a minimal userborn + immutable-`/etc` system with a declarative
  yescrypt `initialHashedPassword`, asserts `/etc/shadow` is a symlink into
  `/var/lib/nixos`, then shuts down and cold-starts the same persistent qcow2
  to prove the hash survived.

## CI

`.forgejo/workflows/ci.yml` (Codeberg Forgejo Actions) runs two lanes:

- **lint** (every push + PR): `nix flake check --no-build` + the cheap eval
  checks, and `cargo fmt/clippy/test` for `rust/installer-tui/`. Runs on the hosted
  `codeberg-medium` runner inside `nixos/nix` / `rust` containers.
- **vm** (weekly + manual): builds the boot check with
  `--option system-features "… kvm"`. Codeberg's hosted runners have no
  `/dev/kvm`, so these jobs target a `self-hosted, kvm` runner — until one is
  registered they stay pending and don't block the lint lane. Serial/driver
  logs are kept as job artifacts either way.