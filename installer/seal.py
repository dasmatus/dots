"""Chroot phase, part 5: seal /usr into a signed dm-verity image + build the UKI.

Everything is emerged and configured; now (1) split the Portage toolchain into
a systemd-sysext so the base /usr stays lean, (2) seal the base /usr into a
read-only erofs + dm-verity image, sign it, write it into the usr_a triplet,
and (3) build the UKI whose cmdline carries usrhash=<roothash>. Runs in the
chroot where erofs-utils/ukify/veritysetup are emerged and /dev (the target
block devices) is bind-mounted."""

import base64
import os
import re
import shutil
import tempfile

import common
import config
from common import die, info, step, write_file

# The emerge toolchain packages split out into the sysext (emerge.raw).
SYSEXT_PACKAGES = [
    "sys-apps/portage", "sys-devel/gcc", "sys-devel/binutils", "sys-devel/make",
    "dev-util/ccache", "dev-vcs/git", "app-portage/portage-utils",
    "app-portage/gentoolkit",
]

EXTENSION_RELEASE = """\
ID=gentoo
SYSEXT_LEVEL=1
ARCHITECTURE=x86-64
"""


def seal_usr():
    step("Seal immutable /usr (erofs + dm-verity) + UKI")

    # usr-merge sanity — the split is only safe if these are symlinks into /usr.
    for link in ("/bin", "/sbin", "/lib", "/lib64"):
        if not os.path.islink(link):
            die(f"not usr-merged ({link} is not a symlink) — cannot seal /usr")
    # SYSEXT_LEVEL decouples sysext matching from the per-build VERSION_ID.
    with open("/usr/lib/os-release") as f:
        osrel = f.read()
    if not re.search(r"^SYSEXT_LEVEL=", osrel, re.MULTILINE):
        with open("/usr/lib/os-release", "a") as f:
            f.write("SYSEXT_LEVEL=1\n")

    work = tempfile.mkdtemp()
    kver = common.kver()
    ver = f"{kver}.0"

    _split_emerge_sysext(work)
    roothash = _seal_base_usr(work)
    _write_slot_a_and_uki(work, kver, ver, roothash)

    shutil.rmtree(work)
    info(f"UKI: /boot/EFI/Linux/gentoo_{ver}.efi (usrhash embedded)")


def _split_emerge_sysext(work):
    """(1) emerge toolchain sysext — collect the toolchain's /usr files, pack
    them into an erofs extension, then prune them from the base /usr."""
    files = set()
    for pkg in SYSEXT_PACKAGES:
        out = common.run_out(["qlist", "-C", pkg], check=False)
        files.update(line for line in out.splitlines() if line.startswith("/usr/"))
    file_list = sorted(files)
    fl_path = os.path.join(work, "emerge.files")
    write_file(fl_path, "\n".join(file_list) + ("\n" if file_list else ""))

    sx_root = os.path.join(work, "emerge-root")
    os.makedirs(f"{sx_root}/usr/lib/extension-release.d", exist_ok=True)
    sx_tar = os.path.join(work, "sx.tar")
    common.run(["tar", "--numeric-owner", "-C", "/", "-cpf", sx_tar, "-T", fl_path],
               check=False, quiet=True)
    common.run(["tar", "-C", sx_root, "-xpf", sx_tar], check=False, quiet=True)
    write_file(f"{sx_root}/usr/lib/extension-release.d/extension-release.emerge",
               EXTENSION_RELEASE)
    os.makedirs("/var/lib/extensions", exist_ok=True)
    common.run(["mkfs.erofs", "-zlz4hc", "-T0", "--all-root",
                "/var/lib/extensions/emerge.raw", sx_root], quiet=True)
    for f in file_list:
        try:
            os.remove(f)
        except OSError:
            pass
    info(f"emerge sysext → /var/lib/extensions/emerge.raw ({len(file_list)} files split out)")


def _seal_base_usr(work):
    """(2) seal the lean base /usr; returns the dm-verity roothash."""
    keydir = config.CHROOT_KEYDIR
    erofs = os.path.join(work, "usr.erofs")
    verity = os.path.join(work, "usr.verity")

    common.run(["mkfs.erofs", "-zlz4hc", "-T0", "--all-root", erofs, "/usr"],
               quiet=True)
    fmt = common.run_out(["veritysetup", "format", erofs, verity])
    m = re.search(r"Root hash:\s+(\S+)", fmt)
    if not m:
        die("veritysetup format did not report a root hash")
    roothash = m.group(1)

    # Sign the roothash (bash used `-in <(printf '%s' …)`; a temp file is the
    # same bytes — no trailing newline).
    rh_file = os.path.join(work, "roothash.txt")
    with open(rh_file, "w") as f:
        f.write(roothash)
    p7s = common.run_bin_out(["openssl", "smime", "-sign", "-nocerts", "-noattr",
                              "-binary", "-in", rh_file,
                              "-inkey", f"{keydir}/verity.key",
                              "-signer", f"{keydir}/verity.crt",
                              "-outform", "der"])
    with open(os.path.join(work, "usr.p7s"), "wb") as f:
        f.write(p7s)
    sig_b64 = base64.b64encode(p7s).decode()
    write_file(os.path.join(work, "usr.verity-sig"),
               f'{{"rootHash":"{roothash}","signature":"{sig_b64}"}}')
    info(f"usr dm-verity roothash: {roothash}")
    return roothash


def _write_slot_a_and_uki(work, kver, ver, roothash):
    """(3) write the image triplet into usr_a, then build the UKI with usrhash=."""
    keydir = config.CHROOT_KEYDIR
    common.run(["dd", f"if={work}/usr.erofs",
                "of=/dev/disk/by-partlabel/usr_a",
                "bs=4M", "conv=fsync", "status=none"])
    common.run(["dd", f"if={work}/usr.verity",
                "of=/dev/disk/by-partlabel/usr-verity_a",
                "bs=4M", "conv=fsync", "status=none"])
    common.run(["dd", f"if={work}/usr.verity-sig",
                "of=/dev/disk/by-partlabel/usr-verity-sig_a",
                "bs=1M", "conv=fsync", "status=none"])

    with open("/etc/kernel/cmdline") as f:
        base_cmdline = f.read().replace("\n", " ")
    initrd = os.path.join(work, "initrd")
    common.run(["dracut", "--force", "--no-uefi", "--kver", kver, initrd])
    common.run(["ukify", "build",
                f"--linux=/lib/modules/{kver}/vmlinuz",
                f"--initrd={initrd}",
                f"--cmdline={base_cmdline} usrhash={roothash}",
                "--os-release=@/usr/lib/os-release",
                f"--secureboot-private-key={keydir}/db.key",
                f"--secureboot-certificate={keydir}/db.crt",
                f"--output=/boot/EFI/Linux/gentoo_{ver}.efi"])

    # Seed the sysupdate source dirs so the A slot is version-tracked.
    try:
        shutil.copy2(f"{work}/usr.erofs", f"/var/lib/usr-src/usr_{ver}.erofs")
        shutil.copy2(f"/boot/EFI/Linux/gentoo_{ver}.efi", "/var/lib/uki-src/")
    except OSError:
        pass
