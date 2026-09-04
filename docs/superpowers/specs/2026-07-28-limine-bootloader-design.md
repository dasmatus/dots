# Switch the installed-system bootloader from systemd-boot to Limine

**Date:** 2026-07-28
**Scope:** replace `boot.loader.systemd-boot` with `boot.loader.limine` in
`nix/modules/system/boot.nix` (declarative, no installer Rust changes), update
`nix/README.md`, and add a `limine-install-boot` NixOS test to `tests/default.nix`
that runs the installer plan in a VM and boots the installed system through
Limine, asserting the TPM2-unlocked LUKS root comes up.

## Goal

Stop `nixos-install` from aborting on the installed system's boot chain.
`systemd-boot`'s NixOS installer (`systemd-boot-builder.py`) reads
`/etc/machine-id` with `open("/etc/machine-id").readlines()[0]`, catching only
`ENOENT`. Under this system's impermanence setup — tmpfs `/` (wiped each boot),
`system.etc.overlay.mutable = false` (immutable `/etc`), and `/etc/machine-id`
intentionally **not** persisted (`nix/modules/system/impermanence.nix`) — the install
chroot has an empty/placeholder machine-id, so the builder raises an uncaught
`IndexError` (or older `bootctl` fails "Failed to get machine-id") and
`nixos-install` aborts. Limine's installer (`limine-install.py`) has **zero**
machine-id references, so switching to Limine sidesteps the failure entirely — a
positive reason to switch, not just a workaround.

## Background (verified from the pinned nixpkgs source + research)

- **`boot.loader.limine` exists in the pinned nixpkgs** (nixos-unstable,
  ~2026-07-25) at `nixos/modules/system/boot/loader/limine/`. The module sets
  `system.build.installBootLoader` to a wrapper around `limine-install.py`,
  which `nixos-install` invokes automatically — so the installer Rust code
  (`rust/installer-tui/src/install.rs`) needs no change.
- **ESP is already correct.** `nix/system/disko.nix` carves a 2 G vfat ESP at `/boot`
  (`umask=0077`) on the first disk as a raw GPT partition ("boot loaders can't
  read LVM"). NixOS's default `boot.loader.efi.efiSysMountPoint` is `/boot`, so
  it matches with no extra config. Limine places its files under `/boot/limine/`
  and kernels/initrd under `/boot/limine/kernels/` automatically; there is no
  user-configured kernel/initrd placement option.
- **TPM2 PCR-7 unlock is bootloader-independent.** PCR 7 is the firmware-measured
  Secure Boot policy register (PK/KEK/db/dbx); the GPT is PCR 5, systemd-boot's
  `loader.conf` is PCR 5. Neither systemd-boot nor Limine writes PCR 7. Secure
  Boot is off on both the LiveISO and the installed system, so PCR 7 is
  byte-identical between enrollment (in the installer) and first boot via Limine.
  The unseal itself is done by the systemd initrd (`boot.initrd.systemd.enable =
  true` + disko's `crypttabExtraOpts = [ "tpm2-device=auto" ]`), which Limine
  merely hands the kernel+initrd to. The unlock chain is unchanged.
- **nixpkgs #493017 (unfixed on master).** With `canTouchEfiVariables = true`,
  `limine-install.py` runs `efibootmgr -c` to create an NVRAM boot entry with no
  `try/except`; on firmware that refuses the NVRAM write, `switch-to-configuration
  boot` aborts with "Failed to install bootloader". The clean in-module
  mitigation is `efiInstallAsRemovable = true`, which installs to the
  firmware-default removable path `\EFI\BOOT\BOOTX64.EFI` and skips efibootmgr
  entirely. This installer wipes the whole disk (single-OS), so the removable
  path cannot be contested by another OS.

## Decisions (confirmed with user)

1. **Removable install path.** Set `boot.loader.efi.canTouchEfiVariables = false`
   (was `true`). This makes `efiInstallAsRemovable` default to `true` → Limine
   installs to `\EFI\BOOT\BOOTX64.EFI` and never runs efibootmgr, immune to
   nixpkgs #493017 on arbitrary target firmware. Single clean knob; no need to
   set `efiInstallAsRemovable` explicitly.
2. **Preserve the existing hardening + generation limit via option mapping.**
   `loader.systemd-boot.configurationLimit = 2` → `limine.maxGenerations = 2`.
   `loader.systemd-boot.editor = false` → `limine.enableEditor = false`
   (must be explicit: with Secure Boot off, the module does not force it).
3. **Secure Boot stays off.** `boot.loader.limine.secureBoot.enable` stays at its
   default `false`. Enabling it would flip PCR 7 and break the TPM2 unseal, and
   Limine Secure Boot is upstream-in-development. This matches the existing
   "no Secure Boot" policy (commit `b00f424`).
4. **UEFI-only.** `efiSupport` defaults to `hostPlatform.isEfi` (true);
   `biosSupport` defaults to `!efiSupport && isx86` (false). No BIOS support —
   this system is EFI-only on LVM-on-LUKS with a raw ESP, and BIOS support is
   irrelevant. Leave `biosDevice = "nodev"`.
5. **Add a VM install+boot test** (approach A below), not just eval/build. The
   installed system's boot chain is not exercised by any existing test
   (`iso-boot` only boots the LiveISO). The test must prove the *actual* fix:
   `nixos-install` completes under impermanence (no machine-id crash), Limine
   boots the kernel+initrd off the ESP, and the TPM2 PCR-7 token unseals the
   LUKS-on-LVM root with no recovery-key prompt.

## Design

### 1. `nix/modules/system/boot.nix` — the declarative switch

Replace the `boot.loader.systemd-boot` block with `boot.loader.limine`,
preserving the current hardening and generation limit. Everything else in the
file is unchanged: `plymouth`, `zswap`, `kernelParams`, `initrd.systemd.enable`,
`availableKernelModules`, `hardware.enableRedistributableFirmware`,
`security.tpm2.enable`.

```nix
boot.loader.limine = {
  enable = true;
  maxGenerations = 2;      # was loader.systemd-boot.configurationLimit = 2
  enableEditor = false;    # was loader.systemd-boot.editor = false
  # secureBoot.enable stays false (default) — enabling it would flip PCR 7
  # and break the TPM2 unseal; Limine Secure Boot is upstream-in-development.
};
boot.loader.efi.canTouchEfiVariables = false;
  # was true. Makes efiInstallAsRemovable default to true → Limine installs to
  # \EFI\BOOT\BOOTX64.EFI and SKIPS efibootmgr, immune to nixpkgs #493017.
```

The file's header comment is rewritten: "Boot chain: Limine + systemd initrd
(TPM2 auto-unlock of the disko LUKS volume) + the kernel cmdline carried over
from the retired Gentoo installer. No Secure Boot / UKI signing — Limine boots
the kernel + initrd straight off the ESP and sidesteps the /etc/machine-id
dependency that impermanence + immutable /etc creates for systemd-boot at
install time. See nix/README.md."

### 2. `nix/README.md` — documentation

- Update the "Disk encryption (no Secure Boot)" section: "Boot is plain
  **Limine** off the ESP" replaces "plain `systemd-boot` off the ESP".
- Add a short paragraph: Limine was chosen over systemd-boot because
  `bootctl`/`systemd-boot-builder.py` read `/etc/machine-id`, which is empty at
  `nixos-install` time under impermanence (tmpfs `/` + immutable `/etc` +
  non-persisted machine-id) and aborts the install; Limine has no machine-id
  dependency. The removable install path (`canTouchEfiVariables = false`) avoids
  nixpkgs #493017.
- Note PCR 7 is firmware-measured Secure Boot policy only (bootloader-agnostic),
  so the TPM2 unlock chain is unaffected by the bootloader swap.
- Update the concept-mapping table row "ukify UKI + self-generated Secure Boot
  db keys" → currently maps to "systemd-boot, no Secure Boot …"; update to
  "Limine, no Secure Boot / UKI signing — TPM2 auto-unlock + LUKS recovery key
  only".

### 3. `tests/default.nix` — `limine-install-boot` test (approach A)

Mirror the proven nixpkgs patterns: `nixos/tests/installer.nix` (two-node
install-then-boot, shared qcow2 + state_dir) and `nixos/tests/systemd-initrd-luks-tpm2.nix`
(OVMFFull + swtpm + TPM2 enroll → reboot → assert mount). The dots ISO itself
has **no test instrumentation** (no backdoor shell — `iso-boot` is console-only
by design), so the `installer` node is a **test-instrumented `installation-device`
VM** (with backdoor), not the raw ISO. The install *steps* are identical to
`install.rs::plan()`, so the test still exercises the real install logic
(disko, `nixos-install` + impermanence machine-id, Limine bootloader install,
TPM2 enroll).

- **`installer` node:**
  - `virtualisation.useEFIBoot = true`, `efi.OVMF = pkgs.OVMFFull` (only OVMFFull
    has the TCG/TIS module the swtpm needs), `tpm.enable = true`,
    `mountHostNixStore = true` (so `nixos-install` copies the tokyonight closure
    from the host store — no iso-full, no substitutes).
  - Blank `/dev/vda` as the install target (`emptyDiskImages`).
  - `extraDependencies` includes: the flake input source paths (nixpkgs,
    home-manager, disko — so flake eval works from the host store), `disko`,
    `cryptsetup`, `tpm2-tools`, `nixos-facter`, and the dots flake source
    (copied to `/etc/dots` via `copy_from_host`, then staged to `/tmp/dots-flake`).
  - **Closure-feasibility note:** the committed `tokyonight` closure (built with
    the committed `settings.nix` — real disks/swap) **cannot** be reused here,
    because the test rewrites `settings.nix` with `disks=["/dev/vda"]` and
    `swapSize=1`, which changes the disko-generated `swapDevices`/disk entries
    and therefore the toplevel. With `mountHostNixStore` and no substitutes,
    `nixos-install` can only copy a closure that already exists in the host
    store. So the test must **pre-build the tokyonight closure with the test
    settings** (e.g. evaluate `nixosSystem` with the test `settings` override, or
    write the test `settings.nix` into a copied flake and build `#tokyonight`
    from it) and put that toplevel in `extraDependencies`. Then
    `nixos-install --flake /tmp/dots-flake#tokyonight` substitutes it from the
    host store with no network. This mirrors how `iso-full` embeds the closure,
    but lighter (no multi-GB ISO).
  - Boot to multi-user, then run `install.rs::plan()` via `succeed()`:
    1. `umask 077; head -c 64 /dev/urandom > /tmp/dots-luks-pass`
    2. `disko --mode destroy,format,mount --yes-wipe-all-disks --arg disks
       '["/dev/vda"]' --argstr swapSize 1G /etc/dots/nix/system/disko.nix`
    3. Stage flake: `rm -rf /tmp/dots-flake && mkdir -p /tmp/dots-flake && cp
       -rTL /etc/dots /tmp/dots-flake && chmod -R u+w /tmp/dots-flake`
    4. Write `/tmp/dots-flake/nix/data/settings.nix` (test answers:
       `disks = ["/dev/vda"]`, `swapSize = 1`, `hostname = "test"`,
       `username = "test"`) and `/tmp/dots-flake/nix/secrets.nix` (the existing
       `testHash` yescrypt hash of "test") — into the staged flake, matching
       `install.rs`'s `WriteFile`/`WriteSecrets` targets (`STAGED_FLAKE/nix/`).
    5. `nixos-install --root /mnt --no-root-passwd --flake /tmp/dots-flake#tokyonight`
    6. `systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass
       --tpm2-device=auto --tpm2-pcrs=7 /dev/tokyonightvg/root`
    7. `systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass --recovery-key
       /dev/tokyonightvg/root` (capture the recovery key for the log)
    8. `shred -u /tmp/dots-luks-pass`
  - `installer.shutdown()`.

- **`target` node:**
  - `target.state_dir = installer.state_dir` (shares the qcow2 **and the swtpm
    state** — the swtpm owner seed persists, so the sealed LUKS key unseals;
    PCR 7 is re-measured deterministically by OVMF from the unchanged
    Secure-Boot-off state).
  - `virtualisation.useBootLoader = true`, `useEFIBoot = true`,
    `efi.OVMF = pkgs.OVMFFull`, `tpm.enable = true`,
    `virtualisation.diskImage = "./target.qcow2"`, no CD.
  - Boots from the disk's ESP via Limine (the removable `\EFI\BOOT\BOOTX64.EFI`
    that `nixos-install` installed).

- **Assertions:**
  - `target.wait_for_console_text` for the Limine handoff → systemd initrd →
    boot progression (serial console).
  - `target.wait_for_unit("multi-user.target")` (the installed system reaches
    login — only possible if the LUKS root auto-unlocked via TPM2 with no
    recovery-key prompt).
  - Assert `/dev/mapper/cryptroot` (or the btrfs root subvol) is mounted.
  - `globalTimeout` matching `iso-boot`'s 2 h — disko + `nixos-install` under
    TCG is slow.

### 4. CI placement

- **Lint lane (every push + PR):** `nix-lint` runs `nix flake check --no-build`
  (evaluates **all** `checks.x86_64-linux.*`, builds none) + `cargo fmt/clippy/test`
  for the Rust crates. Adding `limine-install-boot` to the `checks` attrset makes
  `nix flake check --no-build` *evaluate* it (catches config/eval regressions)
  without running it — so per-push lint cost is unchanged.
- **vm lane (weekly + manual, self-hosted KVM runner):** `.forgejo/workflows/ci.yml`
  `vm-boot` job builds a matrix of `checks.x86_64-linux.<check>` with
  `--option system-features "nixos-test benchmark big-parallel kvm"`. Add
  `limine-install-boot` to that matrix (`check: [iso-boot, limine-install-boot]`)
  so it actually executes on the KVM runner. Under TCG (no KVM) it would be
  impractically slow, so it stays out of the per-push lane — same stance as
  `iso-boot`.

## Error handling / risks (ranked)

- **High → fixed by this change — machine-id install crash.** The reason for the
  switch. Limine has zero machine-id references; the test proves `nixos-install`
  now completes.
- **High → mitigated — nixpkgs #493017 (efibootmgr NVRAM failure).** Mitigated by
  `canTouchEfiVariables = false` → removable path → efibootmgr never runs. The
  test additionally proves the install completes.
- **High — PCR-7 drift after a firmware / Secure-Boot-policy change.** Existing
  property, not new with Limine. The recovery key slot is the fallback;
  re-enroll with `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`. Document
  near the recovery-key handling.
- **Medium → mitigated — `enableEditor` hardening.** Re-expressed as
  `enableEditor = false` explicitly.
- **Medium — PCR 7 without Secure Boot = low integrity.** Existing property; out
  of scope for this change. An attacker with physical access can swap Limine /
  kernel / initrd and PCR 7 stays the same, so the TPM unseals for tampered
  components. Limine adds no TPM measurement to compensate. Noted, not addressed
  here.
- **Low — `maxGenerations`.** Set to 2 to match the prior
  `configurationLimit = 2`; the 2 G ESP is generous for two generations.

## Files touched

- `nix/modules/system/boot.nix` — the switch + rewritten header comment.
- `nix/README.md` — boot-chain, machine-id rationale, PCR-7 note,
  concept-mapping row.
- `tests/default.nix` — add `limine-install-boot`.
- `tests/README.md` — add a row to the checks table + a "How it works" bullet.
- `.forgejo/workflows/ci.yml` — add `limine-install-boot` to the `vm-boot`
  matrix.
- No change to `flake/checks.nix` or `flake/apps.nix` — the new test is wired in
  via `tests/default.nix` (already merged into `checks.x86_64-linux` in
  `flake.nix`); `nix flake check --no-build` evaluates it automatically in the
  lint lane.
- No change to `rust/installer-tui/` (the installer plan is unchanged —
  `nixos-install` invokes the Limine `installBootLoader` hook automatically, and
  `systemd-cryptenroll` is bootloader-independent).
- No change to `nix/system/disko.nix` (the ESP is already a raw vfat partition).