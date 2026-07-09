"""Pre-chroot target configuration: Portage config, fstab/crypttab, bind
mounts, and staging (signing keys + this installer package) into the chroot."""

import os
import shutil

import common
import config
from common import info, step, write_file

# make.conf — matches dots repo make.conf.intel; dots repo overwrites at end of chroot
MAKE_CONF = """\
COMMON_FLAGS="-O2 -march=skylake -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j12"
LC_MESSAGES=en_US.utf8

USE="X wayland i3wm icons apparmor pipewire standalone systemd flatpak gles2 alsa hardened multilib pulseaudio -d -fortran -rust -ipv6 -ada -qt5 -qt6"
VIDEO_CARDS="intel i915"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

FEATURES="getbinpkg binpkg-request-signature ccache parallel-fetch parallel-install"
CCACHE_DIR="/var/cache/ccache"
"""

# Official Gentoo binary package host — install prebuilt binpkgs where they
# match (USE/ABI), falling back to source. Speeds the install and later upgrades.
BINHOST_CONF = """\
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
"""

NOTMPFS_ENV = """\
PORTAGE_TMPDIR="/var/tmp/notmpfs"
"""

PACKAGE_ENV = """\
# Giant builds that can exceed RAM → build on disk instead of the tmpfs.
dev-lang/rust               notmpfs.conf
dev-lang/ghc                notmpfs.conf
dev-lang/spidermonkey       notmpfs.conf
sys-devel/llvm              notmpfs.conf
sys-devel/clang             notmpfs.conf
sys-devel/gcc               notmpfs.conf
llvm-core/llvm              notmpfs.conf
llvm-core/clang             notmpfs.conf
www-client/chromium         notmpfs.conf
www-client/firefox          notmpfs.conf
www-client/brave-browser    notmpfs.conf
mail-client/thunderbird     notmpfs.conf
app-office/libreoffice      notmpfs.conf
net-libs/webkit-gtk         notmpfs.conf
dev-qt/qtwebengine          notmpfs.conf
app-emulation/qemu          notmpfs.conf
"""

PACKAGE_USE = {
    "gpg": "app-crypt/gnupg smartcard usb\n",
    "iucode": "sys-firmware/intel-microcode initramfs\n",
    "libsndfile": "media-libs/libsndfile minimal\n",
    "networkmanager": "net-misc/networkmanager iwd wifi\n",
    "openssh": "net-misc/openssh -static\n",
    "systemd": (
        "sys-apps/systemd boot ukify homed repart sysupdate cryptsetup tpm\n"
        "sys-kernel/installkernel systemd dracut ukify\n"
    ),
}

CRYPTTAB = """\
# root: NOT here — systemd-gpt-auto-generator + systemd-cryptsetup TPM2-unlock it
#       from the LUKS2 systemd-tpm2 token. No entry, no passphrase.
# swap: fresh random key every boot (no persistence, no hibernation).
cryptswap  /dev/disk/by-partlabel/swap  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096
"""


def _fstab(efi_uuid, btrfs_uuid):
    opts = config.BTRFS_OPTS
    return f"""\
# <device>            <dir>        <type>  <options>                                     <d> <p>
# / is auto-mounted by systemd-gpt-auto-generator (DPS root-x86-64, TPM2-unlocked,
# default subvol @root) — intentionally NO / entry. /usr is the read-only
# dm-verity image (usrhash= in the UKI); also NOT an fstab entry.
UUID={efi_uuid}        /boot            vfat  defaults,umask=0077                           0   2
UUID={btrfs_uuid}      /home            btrfs {opts},subvol=@home                    0   0
UUID={btrfs_uuid}      /.snapshots      btrfs {opts},subvol=@snapshots               0   0
# Portage scratch = @builds subvol (nodatacow); giants build here via package.env.
UUID={btrfs_uuid}      /var/tmp/notmpfs btrfs {opts},subvol=@builds,nodatacow        0   0
# Small/medium Portage builds go to RAM; overflow → zswap → encrypted swap.
tmpfs                   /var/tmp/portage tmpfs noatime,nosuid,nodev,mode=0775,uid=250,gid=250,size=60% 0 0
# Encrypted swap (random key each boot); zswap fronts it (see kernel cmdline).
/dev/mapper/cryptswap   none             swap  sw                                           0   0
"""


def configure(ctx, keydir, pkg_dir):
    mount = config.MOUNT

    # ── Portage config (pre-chroot) ──────────────────────────────
    step("Portage configuration")
    os.makedirs(f"{mount}/etc/portage/package.use", exist_ok=True)
    write_file(f"{mount}/etc/portage/make.conf", MAKE_CONF)
    write_file(f"{mount}/etc/portage/binrepos.conf/gentoobinhost.conf", BINHOST_CONF)
    # Portage builds happen in the /var/tmp/portage tmpfs (see fstab). Packages
    # too big for RAM fall back to an on-disk build dir via package.env.
    write_file(f"{mount}/etc/portage/env/notmpfs.conf", NOTMPFS_ENV)
    write_file(f"{mount}/etc/portage/package.env", PACKAGE_ENV)
    for name, content in PACKAGE_USE.items():
        write_file(f"{mount}/etc/portage/package.use/{name}", content)

    # ── fstab / crypttab ─────────────────────────────────────────
    efi_uuid = common.run_out(["blkid", "-s", "UUID", "-o", "value",
                               config.PART_EFI]).strip()
    ctx["efi_uuid"] = efi_uuid
    write_file(f"{mount}/etc/fstab", _fstab(efi_uuid, ctx["btrfs_uuid"]))
    write_file(f"{mount}/etc/crypttab", CRYPTTAB)
    info("fstab and crypttab written")

    # ── Bind mounts for chroot ───────────────────────────────────
    for d in ("proc", "sys", "dev", "dev/pts"):
        common.run(["mount", "--bind", f"/{d}", f"{mount}/{d}"])
    common.run(["mount", "--make-rslave", f"{mount}/sys"])
    common.run(["mount", "--make-rslave", f"{mount}/dev"])

    # ── Stage chroot inputs ──────────────────────────────────────
    step("Staging keys + installer package into the chroot")
    # Copy the signing keys into the chroot so the /usr seal (which runs inside
    # the chroot, where erofs-utils + ukify are emerged) can sign the verity
    # roothash and the UKI. /run is not bind-mounted into the chroot, so stage
    # them on-disk (root-only).
    keydst = mount + config.CHROOT_KEYDIR
    os.makedirs(keydst, exist_ok=True)
    os.chmod(keydst, 0o700)
    for f in ("verity.key", "verity.crt", "db.key", "db.crt"):
        shutil.copy2(os.path.join(keydir, f), keydst)

    # The chroot phase is this same package, run as
    # `python3 /root/installer/main.py --phase chroot` (values travel as env
    # vars — see main.run_chroot_install). pkg_dir is the /run snapshot taken
    # BEFORE mounting (the running copy may be shadowed under MOUNT).
    shutil.copytree(pkg_dir, f"{mount}/root/installer", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("__pycache__"))
