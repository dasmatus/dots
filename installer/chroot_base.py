"""Chroot phase, part 1: locale/timezone, Portage sync + overlays, ccache,
systemd stack, kernel + firmware, initramfs (dracut) config + signing keys.

Runs INSIDE the target (main.py --phase chroot). The clean env (PATH etc.) is
set by the chroot invocation itself, so there is no `source /etc/profile` —
everything the installer calls is reached via the explicit PATH.
"""

import os
import shutil

import common
import config
from common import info, step, write_file

LOCALE_GEN = """\
en_US.UTF-8 UTF-8
"""

CCACHE_CONF = """\
cache_dir = /var/cache/ccache
max_size = 10G
compression = true
"""

# Base cmdline — NO root=/rd.luks/rd.lvm: systemd-gpt-auto-generator discovers
# the TPM2-encrypted root by DPS type on the boot disk; systemd-veritysetup
# mounts /usr from usrhash= (appended at seal). zswap fronts the encrypted swap.
KERNEL_CMDLINE = """\
rw zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc zswap.max_pool_percent=25 quiet loglevel=3 mitigations=auto
"""

DRACUT_CONF = """\
# systemd initrd: systemd-cryptsetup (TPM2 unlock of root) + systemd-veritysetup
# (dm-verity /usr) + btrfs. erofs + dm-verity are forced in as drivers because
# /usr is mounted before modules living on /usr are reachable.
add_dracutmodules+=" systemd crypt btrfs tpm2-tss "
add_drivers+=" dm-verity erofs "
hostonly="yes"
hostonly_cmdline="no"
compress="zstd"
"""


def configure():
    # ── Timezone / locale ────────────────────────────────────────
    step("Timezone and locale")
    common.run(["ln", "-sf", "/usr/share/zoneinfo/UTC", "/etc/localtime"])
    write_file("/etc/timezone", "UTC\n")
    write_file("/etc/locale.gen", LOCALE_GEN)
    common.run(["locale-gen"])
    common.run(["eselect", "locale", "set", "en_US.utf8"])
    common.run(["env-update"])

    # ── Portage sync ─────────────────────────────────────────────
    step("Portage tree sync")
    common.run(["emerge-webrsync", "-q"])
    common.run(["emerge", "--sync", "--quiet"])

    # ── Overlays ─────────────────────────────────────────────────
    step("Overlays")
    common.run(["emerge", "--oneshot", "--quiet",
                "app-eselect/eselect-repository", "dev-vcs/git"])

    # brave-browser overlay
    common.run(["eselect", "repository", "enable", "brave-overlay"], check=False, quiet=True)
    common.run(["emaint", "sync", "-r", "brave-overlay", "-q"], check=False, quiet=True)

    # hyprland extras (hyprlock, hypridle, etc.)
    common.run(["eselect", "repository", "enable", "hyprland"], check=False, quiet=True)
    common.run(["emaint", "sync", "-r", "hyprland", "-q"], check=False, quiet=True)

    # ── ccache ───────────────────────────────────────────────────
    step("ccache")
    common.run(["emerge", "--oneshot", "--quiet", "dev-util/ccache"])
    os.makedirs("/var/cache/ccache", exist_ok=True)
    os.chmod("/var/cache/ccache", 0o2775)
    write_file("/var/cache/ccache/ccache.conf", CCACHE_CONF)

    # ── systemd stack ────────────────────────────────────────────
    # The systemd stage3 ships systemd with default USE. Rebuild it with the
    # flags from package.use (boot, ukify, homed, repart, sysupdate,
    # cryptsetup, tpm) so bootctl / homectl / systemd-repart / ukify all
    # become available.
    step("systemd stack (boot · homed · repart · sysupdate · ukify)")
    common.run(["emerge", "--oneshot", "--quiet", "--newuse", "--changed-use",
                "sys-apps/systemd", "sys-kernel/installkernel"])

    # ── Kernel + firmware ────────────────────────────────────────
    step("Kernel (vanilla-kernel)")
    common.run(["emerge", "--quiet", "--noreplace",
                "sys-kernel/vanilla-kernel",
                "sys-kernel/linux-firmware",
                "sys-firmware/intel-microcode"])
    info(f"Kernel version: {common.kver()}")

    # ── initramfs config (dracut) — the UKI is assembled later, at seal time ──
    # The UKI can only be built AFTER /usr is sealed: its cmdline must carry
    # usrhash=<verity roothash>, unknown until then. Here we only emerge the
    # tools and lay down the initrd config + base cmdline. seal.py builds it.
    step("initramfs config (dracut) + verity/erofs tools")
    common.run(["emerge", "--quiet", "--noreplace",
                "sys-kernel/dracut", "app-crypt/tpm2-tss", "sys-fs/erofs-utils",
                "app-portage/portage-utils"])

    # Stage the signing keys on the MUTABLE root (root-only) so the installed
    # system can re-sign UKIs/roothashes on reseal. They live in /etc (never
    # in the sealed /usr).
    os.makedirs("/etc/kernel/keys", exist_ok=True)
    os.chmod("/etc/kernel/keys", 0o700)
    for f in ("verity.key", "verity.crt", "db.key", "db.crt"):
        shutil.copy2(os.path.join(config.CHROOT_KEYDIR, f), "/etc/kernel/keys/")

    write_file("/etc/kernel/cmdline", KERNEL_CMDLINE)
    write_file("/etc/dracut.conf.d/10-systemd-uki.conf", DRACUT_CONF)
    os.makedirs("/boot/EFI/Linux", exist_ok=True)
