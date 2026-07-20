# TPM2 drive auto-unlock for the installed `cryptroot`

**Date:** 2026-07-20
**Scope:** imperative, one-time enrollment of a TPM2 token (and a recovery key)
on the existing LUKS2 header of `/dev/nvme0n1p3` (`cryptroot`), plus an optional
idempotent re-enroll helper at `scripts/enroll-tpm.sh`. **No NixOS config change
and no flake rebuild are required** — the running initrd is already wired to
consume the token.

## Goal

Stop typing the LUKS passphrase at every boot: bind `cryptroot`'s unlock to the
machine's TPM2 (PCR 7, the Secure Boot policy state) so the initrd auto-unlocks
the volume at boot, with the existing passphrase and a newly-enrolled recovery
key kept as fallbacks.

## Background (verified on the live system)

- Running OS: NixOS 26.11, booted from the exact `nix/disko.nix` layout —
  `cryptroot` LUKS2 on `/dev/nvme0n1p3` (by-partlabel `disk-main-root`), btrfs
  subvols `@root`/`@home`/`@snapshots`/`@builds`, ESP `/boot`, random-key swap.
- Secure Boot is **ON** (efivar `SecureBoot-…` == 1). PCR 7 is therefore
  meaningful: it measures the Secure Boot policy + EFI variables, so the token
  invalidates only on Secure Boot / firmware tampering, **not** on kernel/UKI
  updates. That is the right policy for a frequently-rebuilt NixOS box and is
  what the installer already enrolls (see below).
- TPM2 present: `/dev/tpm0`, `/dev/tpmrm0`, `tpm_version_major = 2`;
  `tpm2-tools` and `systemd-cryptenroll` are in the system profile
  (`/run/current-system/sw/bin/`); `security.tpm2.enable = true` is set in
  `nix/modules/boot.nix`.
- The running initrd's `/etc/crypttab` already contains:
  ```
  cryptroot /dev/disk/by-partlabel/disk-main-root - tpm2-device=auto,discard
  ```
  i.e. `boot.initrd.systemd.enable = true` + `disko.nix`'s
  `crypttabExtraOpts = [ "tpm2-device=auto" ]` are already active in the
  **currently-booted** generation. At boot `systemd-cryptsetup@cryptroot` asks
  the TPM to unseal a key; today it finds **no enrolled token** and falls back
  to the interactive passphrase. **This is the entire gap.**
- The installer (`installer-tui/src/install.rs:208-225`) already enrolls
  exactly this — `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` then
  `--recovery-key` — and saves the recovery key to `/root/luks-recovery.txt`
  (`install.rs:279`). This system predates that step, so the enrollment never
  ran on this disk.

## Decisions (confirmed with user)

1. **Mechanism: `systemd-cryptenroll`** — matches the installer and the running
   initrd's token format. Rejected: `clevis` (second subsystem the repo doesn't
   use) and hand-rolled `cryptsetup luks add-token` (incompatible token shape for
   `systemd-cryptsetup@`).
2. **PCR policy: PCR 7 only** — survives `nixos-rebuild` kernel/UKI updates,
   invalidates on Secure Boot policy change. Aligned with the installer and the
   Secure-Boot-ON state of this machine.
3. **Enroll a recovery key** in addition to the TPM2 token + existing
   passphrase; save it to `/root/luks-recovery.txt` (root, mode `0600`), as the
   installer does. High-entropy escape hatch if the TPM token is invalidated by
   a firmware change and the passphrase is forgotten.
4. **Add `scripts/enroll-tpm.sh`** as an idempotent re-enroll helper for future
   use (after a PCR7 invalidation). It `--wipe-slot`s existing `tpm2`/`recovery`
   slots before re-enrolling so re-runs don't proliferate slots.
5. **No repo/flake change needed for the unlock to take effect** — the next
   boot consumes the newly-enrolled token via the already-present crypttab
   option. The only artifact added to the tree is the optional helper script.

## Procedure (run as root)

Target device uses the stable by-partlabel path, not `nvme0n1p3`:

```bash
DEV=/dev/disk/by-partlabel/disk-main-root

# 1. Enroll TPM2 token bound to PCR 7 (prompts for the existing passphrase)
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$DEV"

# 2. Enroll a recovery key; it is printed to stdout (last non-empty line)
sudo systemd-cryptenroll --recovery-key "$DEV" \
  | tail -n1 | sudo tee /root/luks-recovery.txt >/dev/null
sudo chmod 0600 /root/luks-recovery.txt

# 3. Verify the slots
sudo systemd-cryptenroll "$DEV"
```

For everyday use, run the helper instead: `sudo scripts/enroll-tpm.sh`.

## `scripts/enroll-tpm.sh` (new, idempotent)

- Style: match `scripts/sign-iso.sh` — verbose header comment, `set -euo
  pipefail`, `log/ok/die` helpers, ANSI colors only on a TTY.
- Behavior:
  1. Require root (`$EUID -ne 0` → die).
  2. Resolve `DEV=/dev/disk/by-partlabel/disk-main-root`; die if missing.
  3. `systemd-cryptenroll --wipe-slot=tpm2,recovery "$DEV"` (wipe the two slots
     we own; never touches the passphrase slot). Tolerate "no such slot" on a
     first run.
  4. `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$DEV"`.
  5. `systemd-cryptenroll --recovery-key "$DEV"`, capture stdout, write the
     last non-empty line to `/root/luks-recovery.txt` (`0600`, root).
  6. Print `systemd-cryptenroll "$DEV"` (slot list) for confirmation.
- Each `systemd-cryptenroll` invocation prompts for the existing passphrase to
  authorize the keyslot write (no keyfile on the live system, unlike the
  installer which has `/tmp/dots-luks-pass`).

## Verification

- `systemd-cryptenroll "$DEV"` lists: the original passphrase slot + a `tpm2`
  slot + a `recovery` slot.
- Reboot → no LUKS prompt; `cryptroot` activates from the TPM token; plymouth
  continues straight to the display manager.

## Risks / rollback

- Enrollment only **adds** keyslots; the passphrase slot is never removed, so
  the disk cannot be locked out by this procedure. If auto-unlock misbehaves
  after reboot, fall back to typing the passphrase (today's behavior). To
  remove the TPM slot: `sudo systemd-cryptenroll --wipe-slot=tpm2 "$DEV"`.
- `/root/luks-recovery.txt` lives **inside** the encrypted volume — it is only
  an "already-booted but forgot the passphrase" escape hatch, not a cold-disk
  one. For cold recovery the recovery key must also be stored off-disk (paper,
  password manager). The helper prints it to the TTY so it can be copied.