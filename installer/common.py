"""Logging, subprocess wrappers, checkpoint hook, file helpers.

The output glyphs ([+] / ━━ / [!] / [✗]) and the checkpoint marker line are a
CONTRACT with the VM test harness (tests/smoke.sh greps the serial log) — do
not restyle them. Everything prints flush=True because stdout is a pipe/serial
console during installs (PYTHONUNBUFFERED=1 is also set by install.sh).
"""

import os
import subprocess
import sys

RED = "\033[0;31m"
GRN = "\033[0;32m"
YLW = "\033[0;33m"
CYN = "\033[0;36m"
BLD = "\033[1m"
RST = "\033[0m"


def info(msg):
    print(f"{GRN}[+]{RST} {msg}", flush=True)


def step(msg):
    print(f"\n{CYN}{BLD}━━ {msg} {RST}", flush=True)


def warn(msg):
    print(f"{YLW}[!]{RST} {msg}", flush=True)


def die(msg, rc=1):
    print(f"{RED}[✗]{RST} {msg}", file=sys.stderr, flush=True)
    sys.exit(rc)


def checkpoint(stage):
    """Test checkpoint hook (inert unless INSTALL_STOP_AFTER matches).

    The VM test harness sets INSTALL_STOP_AFTER=<stage> to stop the installer
    at a stage boundary and inspect the on-disk result without running the
    multi-hour emerge/seal phase. Empty/unset never equals a stage name, so
    this is a no-op in normal use. The marker line is machine-parseable
    (tests/smoke.sh greps it).
    """
    if os.environ.get("INSTALL_STOP_AFTER", "") == stage:
        print(f"=== CHECKPOINT:{stage} ===", flush=True)
        sys.exit(0)


def run(cmd, check=True, quiet=False, input_text=None, stdin_devnull=False, cwd=None):
    """subprocess.run with bash `set -e` semantics.

    check=True (default) → die() with a readable message on non-zero exit,
    like an unguarded command under `set -e`. check=False → the `|| true` /
    `|| warn` pattern: returns False instead of aborting.
    quiet → both stdout and stderr to /dev/null (bash `&>/dev/null`).
    stdin_devnull → bash `</dev/null` (guarantees a tool can never block on a
    prompt during the headless install).
    """
    kwargs = {"cwd": cwd}
    if input_text is not None:
        kwargs["input"] = input_text
        kwargs["text"] = True
    elif stdin_devnull:
        kwargs["stdin"] = subprocess.DEVNULL
    if quiet:
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    sys.stdout.flush()
    r = subprocess.run(cmd, **kwargs)
    if check and r.returncode != 0:
        die(f"command failed (rc={r.returncode}): {' '.join(cmd)}")
    return r.returncode == 0


def run_out(cmd, check=True, stdin_devnull=False):
    """Command with captured stdout (bash `$(…)`); stderr passes through."""
    kwargs = {}
    if stdin_devnull:
        kwargs["stdin"] = subprocess.DEVNULL
    r = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, **kwargs)
    if check and r.returncode != 0:
        die(f"command failed (rc={r.returncode}): {' '.join(cmd)}")
    return r.stdout


def run_bin_out(cmd):
    """Command with captured BINARY stdout (openssl der output etc.)."""
    r = subprocess.run(cmd, stdout=subprocess.PIPE)
    if r.returncode != 0:
        die(f"command failed (rc={r.returncode}): {' '.join(cmd)}")
    return r.stdout


def write_file(path, content, mode=0o644):
    """Heredoc replacement: mkdir -p the parent, write content, chmod."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def kver():
    """Highest installed kernel version (bash: ls /lib/modules | sort -V | tail -1)."""
    import re

    def natkey(s):
        return [(0, int(t)) if t.isdigit() else (1, t) for t in re.split(r"(\d+)", s)]

    versions = sorted(os.listdir("/lib/modules"), key=natkey)
    if not versions:
        die("no kernel found under /lib/modules")
    return versions[-1]
