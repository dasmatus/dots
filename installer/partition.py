"""Signing keys + declarative partitioning (systemd-repart + TPM2 + DPS),
root reopen, btrfs subvolumes, install-time encrypted swap."""

import os
import tempfile

import common
import config
from common import die, info, step, warn


def gen_keys():
    """Verity roothash + Secure Boot signing keys.

    Generated locally in the live env; private halves are NEVER sealed into
    the image. Real deployments must persist/manage these offline — the VM
    tests regenerate them per run. verity.crt signs the /usr dm-verity
    roothash; db.key/crt sign the UKI (ukify).
    """
    step("Signing keys (verity + Secure Boot)")
    keydir = tempfile.mkdtemp(prefix="dots-keys.", dir="/run")
    for name, cn in (("verity", "gentoo dm-verity"), ("db", "gentoo secureboot")):
        common.run(["openssl", "req", "-x509", "-newkey", "rsa:4096", "-sha256",
                    "-days", "3650", "-nodes",
                    "-keyout", f"{keydir}/{name}.key",
                    "-out", f"{keydir}/{name}.crt",
                    "-subj", f"/CN={cn}"], quiet=True)
    info(f"keys in {keydir} (verity + SB db)")
    return keydir


def provision(disk):
    """Partition, enroll recovery key, reopen root, create subvols + swap.
    Returns ctx dict {disk, btrfs_uuid} (efi_uuid added by hostconfig)."""
    mount = config.MOUNT

    step(f"Partitioning {disk} (systemd-repart + TPM2)")
    common.run(["sgdisk", "--zap-all", disk], quiet=True)  # clear stale GPT/LUKS headers

    ram_g = config.ram_gib()
    usr_sz = config.usr_size()
    info(f"swap {ram_g}G · /usr slots {usr_sz} (A/B) · root fills remainder")

    # repart.d drop-ins are the single source of truth for the layout. The usr
    # A/B image slots are created EMPTY here (the sealed erofs does not exist
    # until after emerge); they are populated post-seal and by sysupdate
    # thereafter. The SAME set (config.repart_defs) is shipped into the
    # installed system so systemd-repart.service is idempotent.
    repart_dir = tempfile.mkdtemp()
    for fname, content in config.repart_defs(ram_g, usr_sz).items():
        common.write_file(os.path.join(repart_dir, fname), content)

    # --tpm2-pcrs: production binds PCR 7 (SecureBoot state, stable across
    # kernel/UKI updates); the VM tests set TPM2_PCRS= (empty, no PCR policy)
    # to dodge swtpm/OVMF PCR fragility. config.tpm2_pcrs() keeps the bash
    # `${TPM2_PCRS-7}` rule: an explicitly-empty value stays empty.
    common.run([
        "systemd-repart",
        "--dry-run=no",
        "--empty=force",
        f"--definitions={repart_dir}",
        "--tpm2-device=auto",
        f"--tpm2-pcrs={config.tpm2_pcrs()}",
        disk,
    ])

    common.run(["partprobe", disk], check=False, quiet=True)
    common.run(["udevadm", "settle"])
    info("GPT + TPM2-encrypted root created")

    # Recovery key: anti-lockout insurance if PCRs/firmware change. Printed to
    # the console — save it. Adding a keyslot requires unlocking with an
    # EXISTING credential first, so unlock via the TPM2 keyslot repart just
    # enrolled (--unlock-tpm2-device=auto); stdin=/dev/null + timeout guarantee
    # it can never block the headless install on a passphrase prompt.
    step("TPM2 recovery key")
    if not common.run(["timeout", "60", "systemd-cryptenroll",
                       "--unlock-tpm2-device=auto", "--recovery-key",
                       config.PART_ROOT],
                      check=False, stdin_devnull=True):
        warn("recovery-key enroll skipped/failed — continuing (TPM2 unlock still works)")

    # repart created LUKS2 + enrolled the TPM2 + formatted btrfs INSIDE the
    # volume, then closed it. Reopen via the just-enrolled TPM2 token (same
    # boot ⇒ TPM state matches) — no passphrase. Do NOT mkfs; the btrfs exists.
    step("Reopen root (TPM2) + subvolumes")
    if not common.run(["systemd-cryptsetup", "attach", "cryptroot",
                       config.PART_ROOT, "-", "tpm2-device=auto"],
                      check=False, stdin_devnull=True):
        if not common.run(["cryptsetup", "open", "--token-only",
                           config.PART_ROOT, "cryptroot"],
                          check=False, stdin_devnull=True):
            die("could not TPM2-unlock the just-created root")
    btrfs_uuid = common.run_out(["blkid", "-s", "UUID", "-o", "value",
                                 "/dev/mapper/cryptroot"]).strip()
    info(f"root btrfs UUID: {btrfs_uuid}")

    info("Creating subvolumes: @root @home @snapshots @builds")
    common.run(["mount", "/dev/mapper/cryptroot", mount])
    for sv in ("@root", "@home", "@snapshots", "@builds"):
        common.run(["btrfs", "subvolume", "create", f"{mount}/{sv}"])
    # @builds = emerge staging + Portage scratch → nodatacow
    common.run(["chattr", "+C", f"{mount}/@builds"], check=False, quiet=True)
    # gpt-auto mounts @root as / (no rootflags needed)
    common.run(["btrfs", "subvolume", "set-default", f"{mount}/@root"])
    common.run(["umount", mount])

    info("Mounting subvolumes for the build...")
    opts = config.BTRFS_OPTS
    common.run(["mount", "-o", f"{opts},subvol=@root", "/dev/mapper/cryptroot", mount])
    for d in ("home", ".snapshots", "boot", "var/tmp/notmpfs"):
        os.makedirs(f"{mount}/{d}", exist_ok=True)
    common.run(["mount", "-o", f"{opts},subvol=@home", "/dev/mapper/cryptroot", f"{mount}/home"])
    common.run(["mount", "-o", f"{opts},subvol=@snapshots", "/dev/mapper/cryptroot", f"{mount}/.snapshots"])
    common.run(["mount", "-o", f"{opts},subvol=@builds,nodatacow", "/dev/mapper/cryptroot", f"{mount}/var/tmp/notmpfs"])
    common.run(["mount", config.PART_EFI, f"{mount}/boot"])  # ESP doubles as /boot

    # Install-time swap: plain dm-crypt, random key — re-keyed every boot, no
    # persistent secret. Enabled now so install-time emerges have overflow.
    # zswap (kernel cmdline on the installed system) fronts it.
    step("Encrypted swap (install-time)")
    common.run(["cryptsetup", "open", "--type", "plain",
                "--key-file", "/dev/urandom",
                "--cipher", "aes-xts-plain64", "--key-size", "512",
                "--sector-size", "4096",
                config.PART_SWAP, "cryptswap"])
    common.run(["mkswap", "-q", "/dev/mapper/cryptswap"])
    common.run(["swapon", "/dev/mapper/cryptswap"])
    try:  # best-effort now (the live kernel may lack zswap)
        with open("/sys/module/zswap/parameters/enabled", "w") as f:
            f.write("1")
    except OSError:
        pass

    return {"disk": disk, "btrfs_uuid": btrfs_uuid}
