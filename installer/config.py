"""Shared constants + env knobs for the tokyonight-dots Gentoo installer.

Layout summary (see install.sh header + CLAUDE.md): full-systemd,
immutable-/usr Gentoo per Poettering's "Fitting Everything Together".
systemd-repart declaratively creates all partitions (DPS types); /usr is a
sealed read-only erofs + dm-verity image; updates RESEAL via systemd-sysupdate.
"""

import os

DOTS_REPO = "https://gitlab.com/TenTypekMatus/tokyonight-dots"
DOTS_RAW = f"{DOTS_REPO}/-/raw/main"
AFOSI_REPO = "https://gitlab.com/agents-make-an-os/tooling/agent-first-os-installer.git"
KONKRIT_REPO = "https://gitlab.com/agents-make-an-os/tooling/konkrit.git"

# ── Stage3 mirror ────────────────────────────────────────────────
# Default mirror is tux.rainside.sk (override with STAGE3_BASE in the env).
# The pointer file inside the current-* dir is named after the profile
# (latest-stage3-amd64-hardened-selinux-systemd.txt).
STAGE3_BASE = os.environ.get(
    "STAGE3_BASE", "https://tux.rainside.sk/gentoo/releases/amd64/autobuilds"
)
STAGE3_PROFILE = "current-stage3-amd64-hardened-selinux-systemd"
STAGE3_POINTER = "latest-" + STAGE3_PROFILE.removeprefix("current-") + ".txt"
GENTOO_RELENG_KEY = "13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
# Gentoo-controlled key bundle (different origin than the stage3 mirror — that
# separation is what makes the gpg check an AUTHENTICITY check). Contains the
# releng key incl. its current signing subkeys; keyservers are fallback only
# (keys.openpgp.org strips user IDs from unverified keys and gpg then refuses
# the import).
GENTOO_SERVICE_KEYS = "https://qa-reports.gentoo.org/output/service-keys.gpg"

MOUNT = "/mnt"
BTRFS_OPTS = "noatime,compress=zstd:1,space_cache=v2"
ESP_SIZE = "2G"  # holds systemd-boot + A/B UKIs (sysupdate InstancesMax=2)

# Partitions are addressed by their repart GPT label (Discoverable Partitions
# Spec), not by numeric suffix — robust across NVMe/SATA and reorderings.
PART_EFI = "/dev/disk/by-partlabel/ESP"
PART_ROOT = "/dev/disk/by-partlabel/root"
PART_SWAP = "/dev/disk/by-partlabel/swap"
PART_USR_A = "/dev/disk/by-partlabel/usr_a"

# Where the signing keys are staged inside the chroot (hostconfig copies them).
CHROOT_KEYDIR = "/root/keys"


def usr_size():
    """Per-slot /usr image size (A and B); override for small disks."""
    return os.environ.get("USR_SIZE") or "8G"


def tpm2_pcrs():
    """bash `${TPM2_PCRS-7}` semantics: unset → "7" (production binds PCR 7 =
    SecureBoot state); explicitly EMPTY stays empty → no PCR policy (VM tests
    set TPM2_PCRS= to dodge swtpm/OVMF PCR fragility)."""
    return os.environ.get("TPM2_PCRS", "7")


def ram_gib():
    """MemTotal rounded up to whole GiB (awk '($2/1024/1024)+1' truncated)."""
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal"):
                kb = int(line.split()[1])
                return int(kb / 1024 / 1024 + 1)
    raise RuntimeError("MemTotal not found in /proc/meminfo")


def repart_defs(ram_g, usr_sz, esp_sz=ESP_SIZE):
    """The repart.d drop-in set — the single source of truth for the layout.

    Used at install time (partition.py) AND shipped byte-identically into the
    installed system at /etc/repart.d (chroot_sysupdate.py) so
    systemd-repart.service is idempotent: it adopts existing partitions by
    Type+Label and never reformats/re-encrypts a non-empty partition.
    Returns {filename: content}.
    """
    defs = {
        "10-esp.conf": (
            "[Partition]\n"
            "Type=esp\n"
            "Format=vfat\n"
            "Label=ESP\n"
            f"SizeMinBytes={esp_sz}\n"
            f"SizeMaxBytes={esp_sz}\n"
        ),
        # root: LUKS2 + TPM2-sealed key, btrfs created inside. No size cap ⇒
        # grows into all space left after the fixed partitions.
        "20-root.conf": (
            "[Partition]\n"
            "Type=root\n"
            "Label=root\n"
            "Format=btrfs\n"
            "Encrypt=tpm2\n"
        ),
        # swap: linux-generic (NOT Type=swap) so gpt-auto won't swapon it
        # UNENCRYPTED; crypttab supplies the per-boot random-key crypto.
        "30-swap.conf": (
            "[Partition]\n"
            "Type=linux-generic\n"
            "Label=swap\n"
            f"SizeMinBytes={ram_g}G\n"
            f"SizeMaxBytes={ram_g}G\n"
        ),
    }
    # /usr A/B triplets (dm-verity image content written post-seal). A==B sizes.
    for slot in ("a", "b"):
        defs[f"4{slot}-usr-{slot}.conf"] = (
            "[Partition]\n"
            "Type=usr\n"
            f"Label=usr_{slot}\n"
            f"SizeMinBytes={usr_sz}\n"
            f"SizeMaxBytes={usr_sz}\n"
        )
        defs[f"5{slot}-usrverity-{slot}.conf"] = (
            "[Partition]\n"
            "Type=usr-verity\n"
            f"Label=usr-verity_{slot}\n"
            "SizeMinBytes=512M\n"
            "SizeMaxBytes=512M\n"
        )
        defs[f"6{slot}-usrveritysig-{slot}.conf"] = (
            "[Partition]\n"
            "Type=usr-verity-sig\n"
            f"Label=usr-verity-sig_{slot}\n"
            "SizeMinBytes=4M\n"
            "SizeMaxBytes=4M\n"
        )
    return defs
