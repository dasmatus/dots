"""Stage3 download, verification and extraction.

The mirror default (tux.rainside.sk) + profile live in config.py; the pointer
file name is derived from the profile (latest-stage3-amd64-hardened-selinux-
systemd.txt — the old hardcoded latest-stage3-amd64-systemd.txt 404s)."""

import os
import re
import shutil

import common
import config
from common import die, info, step, warn


def install():
    mount = config.MOUNT

    step("Stage3 download")
    pointer_url = f"{config.STAGE3_BASE}/{config.STAGE3_PROFILE}/{config.STAGE3_POINTER}"
    latest = common.run_out(["curl", "-fsSL", pointer_url])

    # The pointer file is PGP-clearsigned (-----BEGIN PGP…) and has # comments —
    # select the line that actually names the tarball, not armor/comment lines.
    s3file = None
    for line in latest.splitlines():
        if re.search(r"\.tar\.(xz|gz)", line):
            s3file = line.split()[0]
            break
    if not s3file:
        die("could not parse stage3 filename from latest-stage3 pointer")
    stage3_url = f"{config.STAGE3_BASE}/{config.STAGE3_PROFILE}/{s3file}"

    tarball = f"{mount}/stage3.tar.xz"
    info(f"Fetching: {stage3_url}")
    common.run(["curl", "-fsSL", stage3_url, "-o", tarball])
    common.run(["curl", "-fsSL", f"{stage3_url}.asc", "-o", f"{tarball}.asc"],
               check=False, quiet=True)

    if shutil.which("gpg") and os.path.isfile(f"{tarball}.asc"):
        common.run(["gpg", "--keyserver", "hkps://keys.openpgp.org",
                    "--recv-keys", config.GENTOO_RELENG_KEY],
                   check=False, quiet=True)
        if common.run(["gpg", "--verify", f"{tarball}.asc", tarball],
                      check=False, quiet=True):
            info("GPG signature OK")
        else:
            warn("GPG verify failed — continuing (check manually if concerned)")

    info("Extracting...")
    common.run(["tar", "xpf", tarball, "--xattrs-include=*.*",
                "--numeric-owner", "-C", mount])
    os.remove(tarball)
    if os.path.exists(f"{tarball}.asc"):
        os.remove(f"{tarball}.asc")
    shutil.copy2("/etc/resolv.conf", f"{mount}/etc/resolv.conf")

    # The Portage scratch dir /var/tmp/notmpfs is the @builds subvol, already
    # mounted during the reopen step (partition.py).
