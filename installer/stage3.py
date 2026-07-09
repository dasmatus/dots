"""Stage3 download, verification and extraction.

The mirror default (tux.rainside.sk) + profile live in config.py; the pointer
file name is derived from the profile (latest-stage3-amd64-hardened-selinux-
systemd.txt — the old hardcoded latest-stage3-amd64-systemd.txt 404s).

Verification is layered:
  · size      — the pointer file publishes the tarball byte count; a mismatch
                is an incomplete/corrupt download → HARD FAIL
  · sha256    — against the mirror's .sha256 file → HARD FAIL on mismatch
                (same-origin, so this proves integrity, not authenticity)
  · gpg       — authenticity against the Gentoo releng key; best-effort
                (keyservers are often unreachable in live envs / VMs) but the
                full gpg output is shown so a failure is diagnosable
"""

import hashlib
import os
import re
import shutil
import subprocess
import time

import common
import config
from common import die, info, step, warn


def install():
    mount = config.MOUNT

    step("Stage3 download")
    info(f"Mirror : {config.STAGE3_BASE}")
    info(f"Profile: {config.STAGE3_PROFILE}")
    pointer_url = f"{config.STAGE3_BASE}/{config.STAGE3_PROFILE}/{config.STAGE3_POINTER}"
    info(f"Pointer: {pointer_url}")
    latest = common.run_out(["curl", "-fsSL", pointer_url])

    # The pointer file is PGP-clearsigned (-----BEGIN PGP…) and has # comments —
    # select the line that actually names the tarball, not armor/comment lines.
    # Format: "<filename> <size-in-bytes>".
    s3file, expected_size = None, 0
    for line in latest.splitlines():
        if re.search(r"\.tar\.(xz|gz)", line):
            fields = line.split()
            s3file = fields[0]
            if len(fields) > 1 and fields[1].isdigit():
                expected_size = int(fields[1])
            break
    if not s3file:
        die("could not parse stage3 filename from latest-stage3 pointer")
    stage3_url = f"{config.STAGE3_BASE}/{config.STAGE3_PROFILE}/{s3file}"

    tarball = f"{mount}/stage3.tar.xz"
    if expected_size:
        info(f"Fetching: {stage3_url} ({expected_size / 2**20:.0f} MiB)")
    else:
        warn("pointer file did not state a size — downloading without a size check")
        info(f"Fetching: {stage3_url}")
    _fetch_with_progress(stage3_url, tarball, expected_size)

    actual_size = os.path.getsize(tarball)
    info(f"Downloaded {actual_size:,} bytes")
    if expected_size and actual_size != expected_size:
        die(f"size mismatch: got {actual_size:,} bytes, pointer file says "
            f"{expected_size:,} — incomplete or corrupt download")
    if expected_size:
        info("size matches the pointer file")

    _verify_sha256(tarball, s3file, stage3_url)
    _verify_gpg(tarball, stage3_url)

    info("Extracting...")
    common.run(["tar", "xpf", tarball, "--xattrs-include=*.*",
                "--numeric-owner", "-C", mount])
    os.remove(tarball)
    if os.path.exists(f"{tarball}.asc"):
        os.remove(f"{tarball}.asc")
    shutil.copy2("/etc/resolv.conf", f"{mount}/etc/resolv.conf")

    # The Portage scratch dir /var/tmp/notmpfs is the @builds subvol, already
    # mounted during the reopen step (partition.py).


def _fetch_with_progress(url, dest, expected_size):
    """curl the tarball while printing progress lines every few seconds.

    curl suppresses its own progress meter when stderr is not a TTY (serial
    console / pipe), so poll the growing file instead — one short line per
    interval keeps the serial log readable."""
    proc = subprocess.Popen(["curl", "-fsSL", url, "-o", dest])
    t0 = time.monotonic()
    while proc.poll() is None:
        time.sleep(5)
        if proc.poll() is not None:
            break
        try:
            got = os.path.getsize(dest)
        except OSError:
            got = 0
        elapsed = time.monotonic() - t0
        rate = got / 2**20 / elapsed if elapsed > 0 else 0
        if expected_size:
            pct = got * 100 // expected_size
            info(f"  … {got / 2**20:>6.0f} / {expected_size / 2**20:.0f} MiB "
                 f"({pct}%) at {rate:.1f} MiB/s")
        else:
            info(f"  … {got / 2**20:>6.0f} MiB at {rate:.1f} MiB/s")
    if proc.returncode != 0:
        die(f"stage3 download failed (curl rc={proc.returncode}): {url}")


def _verify_sha256(tarball, s3file, stage3_url):
    """Check the tarball against the mirror's (clearsigned) .sha256 file.
    Same-origin as the tarball → proves integrity (no truncation/corruption),
    not authenticity; gpg below covers authenticity."""
    sha_txt = common.run_out(["curl", "-fsSL", f"{stage3_url}.sha256"], check=False)
    m = re.search(r"^([0-9a-f]{64})\s+" + re.escape(s3file) + r"\s*$",
                  sha_txt, re.MULTILINE)
    if not m:
        warn("no .sha256 published for this tarball — skipping checksum")
        return
    want = m.group(1)
    info(f"Verifying SHA256 (expected {want})…")
    h = hashlib.sha256()
    with open(tarball, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    got = h.hexdigest()
    if got != want:
        die(f"SHA256 mismatch: computed {got} — corrupt download")
    info("SHA256 OK")


def _verify_gpg(tarball, stage3_url):
    """Authenticity check against the Gentoo releng key. Best-effort (a live
    env often cannot reach a keyserver), but every gpg message is shown."""
    if not shutil.which("gpg"):
        warn("gpg not available in the live env — skipping signature check")
        return
    if not common.run(["curl", "-fsSL", f"{stage3_url}.asc",
                       "-o", f"{tarball}.asc"], check=False, quiet=True):
        warn("no .asc signature published for this tarball — skipping gpg check")
        return
    info(f"Importing Gentoo releng key {config.GENTOO_RELENG_KEY}…")
    if not common.run(["gpg", "--keyserver", "hkps://keys.openpgp.org",
                       "--recv-keys", config.GENTOO_RELENG_KEY], check=False):
        warn("keyserver fetch failed (offline/blocked?) — gpg verify will "
             "fail without the key")
    if common.run(["gpg", "--verify", f"{tarball}.asc", tarball], check=False):
        info("GPG signature OK")
    else:
        warn("GPG verify FAILED (see gpg output above) — continuing because "
             "size + SHA256 already matched the mirror; investigate if the "
             "key import succeeded yet the signature still fails")
