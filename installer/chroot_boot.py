"""Chroot phase, part 2: systemd-boot, the rebuild-uki helper, the reseal
update path (sysext-update + gentoo-reseal.service) and the continuous
update check (portage-sync.timer + reseal-on-suspend hook).

The payloads below are runtime scripts/units for the INSTALLED system — they
stay bash/ini (embedded verbatim, matching the original heredocs)."""

import os

import common
from common import info, step, warn, write_file

LOADER_CONF = """\
timeout 5
console-mode keep
# entries are auto-discovered from /EFI/Linux/*.efi (the UKIs)
"""

# Re-bakes the UKI from the base cmdline (/etc/kernel/cmdline) + konkrit's
# drop-ins (/etc/kernel/cmdline.d/*.conf), PRESERVING the current usrhash=
# (read from the running kernel's /proc/cmdline) so the dm-verity /usr binding
# survives a cmdline-only change. Assembled with ukify (not dracut --uefi) and
# signed with the staged Secure-Boot key. Lives in the sealed /usr; writes to
# /boot + reads keys from the mutable /etc. konkrit's kernel/boot-param
# modules call this.
REBUILD_UKI = r"""#!/usr/bin/env bash
set -euo pipefail
KVER=$(ls /lib/modules/ | sort -V | tail -1)
base=$(tr '\n' ' ' < /etc/kernel/cmdline 2>/dev/null || true)
extra=""
if compgen -G "/etc/kernel/cmdline.d/*.conf" >/dev/null 2>&1; then
  extra=$(cat /etc/kernel/cmdline.d/*.conf | grep -vE '^\s*#' | tr '\n' ' ')
fi
# Preserve the active dm-verity /usr binding.
usrhash=$(sed -n 's/.*\busrhash=\([0-9a-f]\+\).*/\1/p' /proc/cmdline)
[[ -n "${usrhash}" ]] && extra+=" usrhash=${usrhash}"
dracut --force --no-uefi --kver "${KVER}" /tmp/initrd.$$
ukify build --linux="/lib/modules/${KVER}/vmlinuz" --initrd="/tmp/initrd.$$" \
  --cmdline="${base} ${extra}" \
  --secureboot-private-key=/etc/kernel/keys/db.key \
  --secureboot-certificate=/etc/kernel/keys/db.crt \
  --output="/boot/EFI/Linux/gentoo_${KVER}.efi"
rm -f /tmp/initrd.$$
"""

# On a read-only dm-verity /usr you cannot emerge in place or rebuild the UKI
# against the live tree. Instead the WHOLE update cycle is one idle-priority
# script: merge the emerge toolchain (sysext) → emerge @world into a staging
# root → seal the new /usr (erofs+verity+sign) + build a new UKI (new usrhash)
# → hand both to systemd-sysupdate for an A/B swap. gentoo-reseal.service runs it.
SYSEXT_UPDATE = r"""#!/usr/bin/env bash
set -euo pipefail
exec 9>/run/gentoo-reseal.lock; flock -n 9 || { echo "reseal already running"; exit 0; }

FLAG=/var/lib/portage/.updates-pending
[[ -e ${FLAG} ]] || { echo "no updates pending"; exit 0; }

STAGING=/var/tmp/notmpfs/staging          # @builds subvol (mutable, nodatacow)
KEYS=/etc/kernel/keys
SRC_USR=/var/lib/usr-src ; SRC_UKI=/var/lib/uki-src
KVER=$(ls /lib/modules/ | sort -V | tail -1)

cleanup(){ systemd-sysext unmerge 2>/dev/null || true; }
trap cleanup EXIT

echo "[reseal] merging emerge toolchain (sysext)…"
systemd-sysext merge

echo "[reseal] emerging @world into staging (live /usr untouched)…"
rm -rf "${STAGING}"; mkdir -p "${STAGING}" "${SRC_USR}" "${SRC_UKI}"
emerge --root="${STAGING}" --config-root="${STAGING}" -uDN --keep-going @world
emerge --root="${STAGING}" @preserved-rebuild || true

echo "[reseal] sealing new /usr (erofs + dm-verity + sign)…"
ver="${KVER}.$(date -u +%Y%m%d%H%M%S)"
erofs="${SRC_USR}/usr_${ver}.erofs"
mkfs.erofs -zlz4hc -T0 --all-root "${erofs}" "${STAGING}/usr"
roothash=$(veritysetup format "${erofs}" "${SRC_USR}/usr_${ver}.verity" | awk '/Root hash/{print $3}')
openssl smime -sign -nocerts -noattr -binary -in <(printf '%s' "${roothash}") \
  -inkey "${KEYS}/verity.key" -signer "${KEYS}/verity.crt" -outform der \
  > "${SRC_USR}/usr_${ver}.p7s"
printf '{"rootHash":"%s","signature":"%s"}' \
  "${roothash}" "$(base64 -w0 "${SRC_USR}/usr_${ver}.p7s")" \
  > "${SRC_USR}/usr_${ver}.verity-sig"

echo "[reseal] building UKI (usrhash=${roothash})…"
base=$(tr '\n' ' ' < /etc/kernel/cmdline)
dracut --force --no-uefi --kver "${KVER}" "/tmp/reseal-initrd.$$"
ukify build --linux="/lib/modules/${KVER}/vmlinuz" --initrd="/tmp/reseal-initrd.$$" \
  --cmdline="${base} usrhash=${roothash}" \
  --secureboot-private-key="${KEYS}/db.key" --secureboot-certificate="${KEYS}/db.crt" \
  --output="${SRC_UKI}/gentoo_${ver}.efi"
rm -f "/tmp/reseal-initrd.$$"

echo "[reseal] systemd-sysupdate A/B swap…"
systemd-sysupdate update
rm -f "${FLAG}"
echo "[reseal] done — reboot into the new slot; the prior slot remains for rollback."
"""

RESEAL_SERVICE = """\
[Unit]
Description=Reseal the OS /usr image and stage an A/B systemd-sysupdate
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/lib/gentoo/sysext-update

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/lib/gentoo/sysext-update
"""

# A low-priority timer keeps the Portage tree synced and flags when @world has
# updates. Suspending then kicks off the RESEAL detached (gentoo-reseal.service).
# getbinpkg keeps the emerge-into-staging fast where prebuilt binaries match.
PORTAGE_CHECK_UPDATES = r"""#!/usr/bin/env bash
set -uo pipefail
flag=/var/lib/portage/.updates-pending
emerge --sync --quiet || exit 0
emaint sync -A -q 2>/dev/null || true
if emerge -puDN --quiet --color=n @world 2>/dev/null | grep -qE '^\[(ebuild|binary)'; then
  mkdir -p /var/lib/portage && touch "${flag}"
else
  rm -f "${flag}"
fi
"""

PORTAGE_SYNC_SERVICE = """\
[Unit]
Description=Sync Portage tree and flag available @world updates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/lib/gentoo/portage-check-updates
"""

PORTAGE_SYNC_TIMER = """\
[Unit]
Description=Periodic Portage sync + update check

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
"""

SLEEP_HOOK = """\
#!/usr/bin/env bash
# On SUSPEND (pre), if a @world upgrade is pending, start the RESEAL detached so
# it does not delay suspend. It freezes through S3 and continues on the next wake
# (a CPU cannot compile during S3), building the next /usr image + A/B sysupdate.
[[ "$1" == "pre" ]] || exit 0
[[ -e /var/lib/portage/.updates-pending ]] || exit 0
systemctl start --no-block gentoo-reseal.service
"""


def configure():
    # ── systemd-boot ─────────────────────────────────────────────
    step("systemd-boot (EFI)")
    # bootctl ships with sys-apps/systemd[boot] (rebuilt in chroot_base).
    # NVRAM writes may fail inside the chroot — the ESP fallback path still boots.
    if not common.run(["bootctl", "install", "--esp-path=/boot"], check=False):
        warn("bootctl NVRAM entry failed — ESP fallback installed, "
             "fix with 'bootctl install' after reboot")
    write_file("/boot/loader/loader.conf", LOADER_CONF)
    info("systemd-boot installed; UKIs auto-discovered from /EFI/Linux")

    # ── rebuild-uki helper ───────────────────────────────────────
    os.makedirs("/etc/kernel/cmdline.d", exist_ok=True)
    os.makedirs("/usr/lib/gentoo", exist_ok=True)
    write_file("/usr/lib/gentoo/rebuild-uki", REBUILD_UKI, mode=0o755)
    common.run(["ln", "-sf", "/usr/lib/gentoo/rebuild-uki",
                "/usr/local/sbin/rebuild-uki"], check=False, quiet=True)

    # ── Reseal update: emerge into staging → seal new /usr → sysupdate A/B ──
    write_file("/usr/lib/gentoo/sysext-update", SYSEXT_UPDATE, mode=0o755)
    write_file("/etc/systemd/system/gentoo-reseal.service", RESEAL_SERVICE)
    info("Reseal update path armed (gentoo-reseal.service → sysext-update)")

    # ── Continuous update check + reseal-on-suspend ──────────────
    write_file("/usr/lib/gentoo/portage-check-updates", PORTAGE_CHECK_UPDATES, mode=0o755)
    write_file("/etc/systemd/system/portage-sync.service", PORTAGE_SYNC_SERVICE)
    write_file("/etc/systemd/system/portage-sync.timer", PORTAGE_SYNC_TIMER)
    write_file("/usr/lib/systemd/system-sleep/60-portage-reseal", SLEEP_HOOK, mode=0o755)
    common.run(["systemctl", "enable", "portage-sync.timer"])
    info("Update check (6h timer) + reseal-on-suspend armed (getbinpkg-accelerated)")
