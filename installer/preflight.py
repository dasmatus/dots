"""Pre-flight checks + disk selection (from the afosi answers)."""

import os
import shutil
import stat

import common
from common import die, info, step, warn

# systemd-repart + bootctl are only present on a systemd live env. Their
# absence means the OpenRC admin CD was booted — bail early with guidance.
# TPM2 + verity are partition-time hard deps. The seal-time tools (mkfs.erofs,
# ukify) are checked separately just before sealing — they are not needed to
# reach the stage3 test checkpoint, and may be absent from a minimal live env.
REQUIRED_TOOLS = [
    "systemd-repart", "systemd-cryptenroll", "bootctl", "cryptsetup",
    "veritysetup", "mkfs.btrfs", "btrfs", "sgdisk", "curl", "openssl",
]


def check():
    step("Pre-flight checks")

    if os.geteuid() != 0:
        die("Must run as root")
    if not os.path.isdir("/sys/firmware/efi"):
        die("UEFI not detected — EFI boot required")

    for cmd in REQUIRED_TOOLS:
        if not shutil.which(cmd):
            die(f"Missing: {cmd}  (boot a systemd live ISO: SystemRescue / Gentoo LiveGUI / Arch)")

    # repart Encrypt=tpm2 + CopyBlocks (used for the sealed /usr) need systemd >= 254.
    first = common.run_out(["systemctl", "--version"]).splitlines()[0]
    try:
        sdver = int(first.split()[1])
    except (IndexError, ValueError):
        sdver = 0
    if sdver < 254:
        die(f"systemd {sdver} too old — need >= 254 for repart TPM2 + CopyBlocks")

    # A TPM2 device is required for passphrase-free auto-unlock (VM: emulated swtpm).
    if not (os.path.exists("/dev/tpmrm0") or os.path.exists("/dev/tpm0")):
        die("no TPM2 device (/dev/tpmrm0) — required for TPM2 unlock (VM needs an emulated swtpm)")


def select_disk():
    step("Disk selection")

    disk = os.environ.get("disk")
    if not disk:
        die("disk answer missing — run via 'installer .steps.yaml'")
    try:
        if not stat.S_ISBLK(os.stat(disk).st_mode):
            raise OSError
    except OSError:
        die(f"Target disk '{disk}' is not a block device")

    # afosi asked the YesNo confirmation; require the affirmative here too.
    if os.environ.get("wipe_confirm", "") != "true":
        die(f"Wipe of {disk} not confirmed — aborting")

    mounts = common.run_out(["lsblk", "-no", "MOUNTPOINTS", disk], check=False)
    if any(line.startswith("/") for line in mounts.splitlines()):
        die(f"{disk} has a mounted partition — refusing to erase")

    info(f"Target disk: {disk}")
    warn(f"ALL DATA ON {disk} WILL BE PERMANENTLY ERASED.")
    return disk
