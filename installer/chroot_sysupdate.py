"""Chroot phase, part 4: installed-system systemd-repart drop-ins,
systemd-sysupdate A/B transfer definitions, first-boot user provisioning."""

import os

import common
import config
from common import info, step, write_file

# All four transfers share @v so one `systemd-sysupdate update` is version-
# consistent: new /usr image+verity+sig into the inactive slot, new UKI into ESP.
SYSUPDATE_UKI = """\
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/uki-src
MatchPattern=gentoo_@v.efi
[Target]
Type=regular-file
Path=/boot/EFI/Linux
MatchPattern=gentoo_@v.efi
Mode=0444
InstancesMax=2
"""

SYSUPDATE_USR = """\
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.erofs
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr
ReadOnly=1
InstancesMax=2
"""

SYSUPDATE_USR_VERITY = """\
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.verity
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr-verity
ReadOnly=1
InstancesMax=2
"""

SYSUPDATE_USR_VERITY_SIG = """\
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.verity-sig
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr-verity-sig
ReadOnly=1
InstancesMax=2
"""

FIRSTBOOT_SH = r"""#!/usr/bin/env bash
set -euo pipefail
mark=/var/lib/gentoo-firstboot.done
[[ -e ${mark} ]] && exit 0

echo
echo "════════════════════════════════════════════════════════════"
echo "  First boot — create your systemd-homed user (LUKS home)"
echo "════════════════════════════════════════════════════════════"
U=""
while [[ -z ${U} ]]; do read -rp "  Username: " U; done

# homectl prompts for the new user's password and builds a per-user LUKS home
# image under /home/${U}.home, populated from /etc/skel (your dotfiles).
homectl create "${U}" \
  --storage=luks \
  --fs-type=btrfs \
  --shell=/usr/bin/fish \
  --member-of=wheel,audio,video,input,usb,plugdev,netdev

# ── konkrit: hardening + Alpine Flatpak VM ───────────────────────
# Point konkrit's {{user}} at the just-created account, then run the full
# catalog + VM. Guarded: konkrit's Arch-targeted steps may abort on Gentoo, and
# that must not block boot. Review /etc/konkrit/konkrit.yaml to curate modules.
if command -v konkrit &>/dev/null && [[ -f /etc/konkrit/konkrit.yaml ]]; then
  echo "  Applying konkrit hardening + Flatpak VM (this may take a while)…"
  sed -i "s|^  user: .*|  user: \"${U}\"|" /etc/konkrit/konkrit.yaml
  konkrit /etc/konkrit/konkrit.yaml \
    || echo "  [!] konkrit stopped early (Arch-targeted steps) — review /etc/konkrit"
fi

touch "${mark}"
systemctl disable gentoo-firstboot.service
echo "  User '${U}' created. Continuing boot…"
"""

FIRSTBOOT_UNIT = """\
[Unit]
Description=First-boot systemd-homed user provisioning
ConditionPathExists=!/var/lib/gentoo-firstboot.done
After=systemd-homed.service systemd-user-sessions.service
Wants=systemd-homed.service
Before=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gentoo-firstboot.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes

[Install]
WantedBy=multi-user.target
"""


def configure():
    # ── systemd-repart (installed-system, idempotent) ────────────
    # Byte-identical to the install-time set (config.repart_defs) so
    # systemd-repart.service is a no-op on an already-provisioned disk, but
    # documents the layout and would re-add a missing ESP / grow into a bigger
    # disk. It adopts existing partitions by Type+Label and NEVER reformats or
    # re-encrypts a non-empty partition (the root already has a LUKS2 header,
    # the usr slots content).
    step("systemd-repart drop-ins (installed system)")
    os.makedirs("/etc/repart.d", exist_ok=True)
    for fname, content in config.repart_defs(config.ram_gib(), config.usr_size()).items():
        write_file(f"/etc/repart.d/{fname}", content)

    # ── systemd-sysupdate (A/B retention: UKI + /usr verity triplet) ──
    step("systemd-sysupdate drop-ins")
    for d in ("/etc/sysupdate.d", "/var/lib/uki-src", "/var/lib/usr-src"):
        os.makedirs(d, exist_ok=True)
    write_file("/etc/sysupdate.d/50-uki.conf", SYSUPDATE_UKI)
    write_file("/etc/sysupdate.d/60-usr.conf", SYSUPDATE_USR)
    write_file("/etc/sysupdate.d/61-usr-verity.conf", SYSUPDATE_USR_VERITY)
    write_file("/etc/sysupdate.d/62-usr-verity-sig.conf", SYSUPDATE_USR_VERITY_SIG)

    # ── First-boot user provisioning (systemd-homed) ─────────────
    step("First-boot user service")
    write_file("/usr/local/sbin/gentoo-firstboot.sh", FIRSTBOOT_SH, mode=0o755)
    write_file("/etc/systemd/system/gentoo-firstboot.service", FIRSTBOOT_UNIT)
    common.run(["systemctl", "enable", "gentoo-firstboot.service"])
    info("First-boot user creation armed on tty1")
