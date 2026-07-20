#!/usr/bin/env bash
# ================================================================
#  scripts/enroll-tpm.sh — (re-)enroll TPM2 auto-unlock for cryptroot
#
#  The installed system already boots with an initrd whose /etc/crypttab
#  carries `tpm2-device=auto` (nix/disko.nix + nix/modules/boot.nix). At boot
#  systemd-cryptsetup@cryptroot asks the TPM to unseal a LUKS key bound to
#  PCR 7 (Secure Boot policy state). If no such token is enrolled in the
#  LUKS2 header it falls back to the interactive passphrase — which is what
#  this script removes by enrolling the token post-install. It is the live
#  equivalent of the installer step at installer-tui/src/install.rs:208-225.
#
#  What it does, as root:
#    1. wipe existing tpm2 + recovery slots we own (NEVER the passphrase slot)
#    2. enroll a TPM2 token bound to PCR 7 — survives nixos-rebuild kernel/UKI
#       updates, invalidates only on Secure Boot / firmware tampering
#    3. enroll a high-entropy recovery key, save it to /root/luks-recovery.txt
#       (0600, root) — an "already-booted, forgot the passphrase" escape hatch
#       (NOT a cold-disk one; for cold recovery also store the key off-disk)
#    4. print the resulting slot list
#
#  Each systemd-cryptenroll invocation prompts for the existing passphrase to
#  authorize the keyslot write — the live system has no /tmp/dots-luks-pass
#  keyfile, unlike the installer.
#
#  Idempotent: safe to re-run after a PCR 7 invalidation (e.g. a Secure Boot
#  policy change) — it wipes our slots first so re-runs don't proliferate them.
#
#  Usage:  sudo scripts/enroll-tpm.sh [--device /dev/disk/by-partlabel/disk-main-root]
# ================================================================
set -euo pipefail

DEV="/dev/disk/by-partlabel/disk-main-root"
while (( $# )); do
  case "$1" in
    --device) DEV="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m' _GRN=$'\033[0;32m' _YEL=$'\033[0;33m' _RST=$'\033[0m'
else
  _RED='' _GRN='' _YEL='' _RST=''
fi
log() { printf '%s[+]%s %s\n' "${_GRN}" "${_RST}" "$*"; }
ok()  { printf '%s[✓]%s %s\n' "${_GRN}" "${_RST}" "$*"; }
die() { printf '%s[✗]%s %s\n' "${_RED}" "${_RST}" "$*" >&2; exit 1; }

(( EUID == 0 )) || die "must run as root (the enrollments write LUKS keyslots)"
command -v systemd-cryptenroll >/dev/null \
  || die "systemd-cryptenroll not found — run on the installed NixOS system"
[[ -e "${DEV}" ]] || die "LUKS device not found: ${DEV} (expected disk-main-root)"
[ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ] || die "no TPM2 device (/dev/tpm0|/dev/tpmrm0)"

RECOVERY_KEY_FILE="/root/luks-recovery.txt"

# 1. Wipe our own slots (tolerate their absence on a first run — wipe-slot
#    returns nonzero when the named slot type has nothing to remove).
log "wiping existing tpm2/recovery slots on ${DEV} (passphrase slot untouched)"
if ! systemd-cryptenroll --wipe-slot=tpm2,recovery "${DEV}" 2>/dev/null; then
  printf '%s[!]%s no existing tpm2/recovery slots to wipe (first run)\n' "${_YEL}" "${_RST}"
fi

# 2. Enroll the TPM2 token bound to PCR 7.
log "enrolling TPM2 token (PCR 7) — enter the current LUKS passphrase when prompted"
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "${DEV}"
ok "TPM2 token enrolled"

# 3. Enroll a recovery key; systemd-cryptenroll prints it to stdout. Password
#    prompts go to the tty, so stdout carries only the key + a trailing blank.
log "enrolling recovery key — enter the current LUKS passphrase again"
key_out="$(systemd-cryptenroll --recovery-key "${DEV}")"
recovery_key="$(printf '%s\n' "${key_out}" | sed '/^[[:space:]]*$/d' | tail -n1)"
[[ -n "${recovery_key}" ]] \
  || die "no recovery key captured from systemd-cryptenroll stdout"
install -m 0600 /dev/null "${RECOVERY_KEY_FILE}"
printf '%s\n' "${recovery_key}" > "${RECOVERY_KEY_FILE}"
ok "recovery key saved to ${RECOVERY_KEY_FILE} (mode 0600)"
# Echo the key to the TTY (stderr) so it can be copied to off-disk storage —
# it was captured into a variable above, so without this the user never sees it.
printf '%s[!]%s recovery key (store a copy off-disk — paper / password manager):\n  %s\n' \
  "${_YEL}" "${_RST}" "${recovery_key}" >&2

# 4. Show the resulting slot list.
log "slot list:"
systemd-cryptenroll "${DEV}"

cat >&2 <<EOF

${_GRN}Done.${_RST} Reboot to confirm auto-unlock (no LUKS prompt).

  - TPM2 token bound to PCR 7 (Secure Boot policy). It auto-invalidates if
    Secure Boot / firmware policy changes; re-run this script to re-enroll.
  - Recovery key: ${RECOVERY_KEY_FILE} (on the encrypted root, root-readable
    only after unlock). For COLD-disk recovery you must ALSO store it off-disk
    (paper / password manager). It was printed on the line above — copy it now.
  - Passphrase slot is untouched; if auto-unlock misbehaves, type the
    passphrase at boot as before. Remove the TPM slot with:
      sudo systemd-cryptenroll --wipe-slot=tpm2 ${DEV}
EOF