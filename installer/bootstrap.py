"""afosi prompt front-end (first pass only).

The user-facing entry point stays `curl install.sh | bash`. On the first pass
we build the afosi `installer` binary, stage stable on-disk copies of
install.sh + .steps.yaml + this package under /root, then exec afosi: it asks
the questions on the TTY and its final Action re-enters `bash /root/install.sh`
with every answer (disk, hostname, root_password, wipe_confirm) exported as an
env var + AFOSI_DRIVEN=1. The second pass skips this module and runs headless.
"""

import os
import shutil

import common
import config
from common import die, info, step


def run():
    if os.geteuid() != 0:
        die("Must run as root")
    step("Bootstrapping the afosi prompt front-end")
    if not shutil.which("git"):
        die("git required in the live env")
    if not shutil.which("cargo"):
        die("Rust/cargo required in the live env to build afosi "
            "(e.g. 'pacman -Sy rust' on an Arch/SystemRescue ISO)")

    if not shutil.which("installer"):
        info("Building afosi installer (cargo, release)…")
        common.run(["cargo", "install", "--quiet", "--git", config.AFOSI_REPO,
                    "--root", "/usr/local"])

    # afosi's action re-runs `bash /root/install.sh`; stage stable on-disk
    # copies of the wrapper, the steps config and this package. Prefer the
    # local repo checkout next to this package (9p share / git clone); fall
    # back to fetching from the raw URL (curl|bash case).
    info("Staging install.sh + .steps.yaml + installer/ under /root…")
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    if pkg_dir != "/root/installer":
        shutil.copytree(pkg_dir, "/root/installer", dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    repo_root = os.path.dirname(pkg_dir)
    for name in ("install.sh", ".steps.yaml"):
        local = os.path.join(repo_root, name)
        if os.path.isfile(local):
            if os.path.abspath(local) != f"/root/{name}":
                shutil.copy2(local, f"/root/{name}")
        else:
            common.run(["curl", "-fsSL", f"{config.DOTS_RAW}/{name}",
                        "-o", f"/root/{name}"])

    # Hand off: stdin from the real TTY so afosi's TUI works under `curl|bash`.
    tty = os.open("/dev/tty", os.O_RDONLY)
    os.dup2(tty, 0)
    os.execvp("installer", ["installer", "/root/.steps.yaml"])
