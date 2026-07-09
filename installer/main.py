#!/usr/bin/env python3
# ================================================================
#  Gentoo automated FDE installer — entry point
#
#  Full-systemd, immutable-/usr Gentoo (per Poettering's "Fitting Everything
#  Together"). systemd-repart declaratively creates all partitions (DPS types):
#    · ESP (2 GiB)
#    · root  → LUKS2 (Encrypt=tpm2, no passphrase) → btrfs  [mutable /etc /var /home]
#              subvols @root @home @snapshots @builds
#    · swap  → linux-generic + crypttab random key (zswap-fronted)
#    · usr {a,b} + usr-verity {a,b} + usr-verity-sig {a,b}  [A/B dm-verity /usr]
#  /usr        : sealed read-only erofs + dm-verity image; roothash signed and
#                baked into the UKI as usrhash=. Toolchain ships as a systemd-sysext
#                (emerge.raw); updates RESEAL (emerge→staging→seal→sysupdate A/B).
#  Bootloader  : systemd-boot + UKI (ukify, signed)   Init: systemd
#
#  Run via install.sh (the curl wrapper):
#    curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
#
#  Phases:
#    (no AFOSI_DRIVEN)   bootstrap — build afosi, hand off to its TUI prompts
#    AFOSI_DRIVEN=1      host      — partition, stage3, configure, run chroot
#    --phase chroot      chroot    — runs INSIDE the target via chroot(1)
#
#  Env: TPM2_PCRS (empty = no PCR policy), USR_SIZE, STAGE3_BASE (mirror),
#       INSTALL_STOP_AFTER (test hook) + the afosi answers (disk, wipe_confirm,
#       hostname, root_password).
# ================================================================

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bootstrap
import chroot_base
import chroot_boot
import chroot_system
import chroot_sysupdate
import common
import config
import hostconfig
import partition
import preflight
import seal
import stage3
from common import checkpoint, info, step


def run_host_phase():
    """Second pass (AFOSI_DRIVEN=1): install answers arrive as env vars
    ($disk $wipe_confirm $hostname $root_password)."""
    preflight.check()
    disk = preflight.select_disk()
    pkg_dir = _snapshot_package()
    keydir = partition.gen_keys()
    ctx = partition.provision(disk)
    checkpoint("partition")
    stage3.install()
    checkpoint("stage3")
    hostconfig.configure(ctx, keydir, pkg_dir)
    run_chroot_install(ctx)
    teardown(keydir)


def _snapshot_package():
    """Copy this package to /run (tmpfs) BEFORE anything is mounted on MOUNT.

    The running copy may live UNDER the mount point — the VM test harness
    shares the repo at /mnt/dotsrepo and MOUNT is /mnt, so mounting the target
    root shadows the source files. The already-imported modules survive in
    memory, but hostconfig later stages the package into the chroot from disk,
    which needs an unshadowed copy."""
    import shutil
    import tempfile

    src = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.join(tempfile.mkdtemp(prefix="dots-installer.", dir="/run"),
                       "installer")
    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__"))
    return dst


def run_chroot_install(ctx):
    """Enter the target with a clean env (replaces the old generated
    install-chroot.sh: values travel as env vars, code as this package,
    staged at /mnt/root/installer by hostconfig)."""
    step("Running chroot installation")
    common.run([
        "chroot", config.MOUNT, "/usr/bin/env", "-i",
        "HOME=/root",
        f"TERM={os.environ.get('TERM', 'xterm')}",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PYTHONUNBUFFERED=1",
        f"hostname={os.environ.get('hostname', 'gentoo')}",
        f"root_password={os.environ.get('root_password', '')}",
        f"BTRFS_UUID={ctx['btrfs_uuid']}",
        f"EFI_UUID={ctx['efi_uuid']}",
        f"DISK={ctx['disk']}",
        f"USR_SIZE={config.usr_size()}",
        f"TPM2_PCRS={config.tpm2_pcrs()}",
        f"INSTALL_STOP_AFTER={os.environ.get('INSTALL_STOP_AFTER', '')}",
        "python3", "/root/installer/main.py", "--phase", "chroot",
    ])


def run_chroot_phase():
    """Runs INSIDE the chroot (erofs-utils/ukify/veritysetup are emerged here
    and /dev — the target block devices — is bind-mounted)."""
    chroot_base.configure()
    chroot_boot.configure()
    chroot_system.configure()
    chroot_sysupdate.configure()
    seal.seal_usr()

    step("Chroot complete")
    info("  Bootloader : systemd-boot + UKI (/boot/EFI/Linux/gentoo_*.efi)")
    info("  /usr       : sealed read-only dm-verity image (usr_a)")
    info("  User       : created on first boot via homectl (LUKS home)")
    info(f"  Hostname   : {os.environ.get('hostname', 'gentoo')}")
    info("  Dotfiles   : staged in /etc/skel (→ ~/ on first login)")


def teardown(keydir):
    step("Unmounting")
    common.run(["umount", "-R", config.MOUNT], check=False, quiet=True)  # also /var/tmp/notmpfs
    common.run(["swapoff", "/dev/mapper/cryptswap"], check=False, quiet=True)
    common.run(["cryptsetup", "close", "cryptswap"], check=False, quiet=True)
    common.run(["cryptsetup", "close", "cryptroot"], check=False, quiet=True)
    import shutil

    shutil.rmtree(keydir, ignore_errors=True)  # wipe the live-env key copy

    print("", flush=True)
    info("Done. Remove install media and reboot.")
    info("On first boot: tty1 prompts you to create your systemd-homed user.")
    info("After logging in, run:  nvim +Lazy +qa   to pull Neovim plugins.")


def main():
    parser = argparse.ArgumentParser(description="tokyonight-dots Gentoo installer")
    parser.add_argument("--phase", choices=["host", "chroot"], default="host")
    args = parser.parse_args()

    if args.phase == "chroot":
        run_chroot_phase()
    elif os.environ.get("AFOSI_DRIVEN", "0") != "1":
        bootstrap.run()  # execs afosi — does not return
    else:
        run_host_phase()


if __name__ == "__main__":
    main()
