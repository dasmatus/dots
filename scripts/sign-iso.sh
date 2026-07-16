#!/usr/bin/env bash
# ================================================================
#  scripts/sign-iso.sh — make the LiveISO bootable under Secure Boot
#
#  Rewrites the ISO's EFI boot chain to:
#    firmware → BOOTX64.EFI (Fedora shim, Microsoft-signed, .#shim-signed)
#             → grubx64.efi (the ISO's own GRUB + injected .sbat, MOK-signed)
#             → /boot/nix/store/…/bzImage (MOK-signed, GRUB verifies it
#               through shim's protocol)
#  plus mmx64.efi (MokManager) and the public cert on the ESP so factory
#  Secure Boot machines can enroll it once from disk. Machines whose db
#  already contains the cert (e.g. sbctl enroll-keys --microsoft + this
#  cert) boot with no prompt — that's what tests/nix-smoke.sh proves in a
#  VM (its default mode).
#
#  Usage:  scripts/sign-iso.sh [-o OUT.iso] [-k KEYDIR] [--shim DIR]
#                              [--sbctl | --extra-sign KEY CERT] UNSIGNED.iso
#    -o      output path        (default result-iso-signed/<name>-signed.iso)
#    -k      key directory      (default secrets/secureboot/ — gitignored;
#                                MOK.key/MOK.crt/MOK.cer generated once, reused)
#    --shim  shim binaries dir  (default: nix build .#shim-signed)
#    --extra-sign KEY CERT      cosign GRUB + kernels with a SECOND key on top
#                               of the MOK (both signatures are kept; PE files
#                               carry both). Machines whose Secure Boot db
#                               already trusts CERT boot with no MokManager
#                               prompt at all, while factory machines still
#                               enroll the MOK once. KEY may be root-owned —
#                               it is read via sudo in place, never copied.
#    --sbctl                    sugar for --extra-sign against the local sbctl
#                               db key (SBCTL_DB or /var/lib/sbctl/keys/db,
#                               files db.key/db.pem) — the same key lanzaboote
#                               signs your installed systems with.
#
#  Tools come from the flake's .#sb-tools — the script re-execs itself
#  inside `nix shell` when they're missing from PATH.
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

if [[ -t 1 ]]; then
  _RED=$'\033[0;31m' _GRN=$'\033[0;32m' _RST=$'\033[0m'
else
  _RED='' _GRN='' _RST=''
fi
log() { printf '%s[+]%s %s\n' "${_GRN}" "${_RST}" "$*"; }
ok()  { printf '%s[✓]%s %s\n' "${_GRN}" "${_RST}" "$*"; }
die() { printf '%s[✗]%s %s\n' "${_RED}" "${_RST}" "$*" >&2; exit 1; }

# ── Toolbelt bootstrap ───────────────────────────────────────────
# Everything beyond coreutils comes from the pinned .#sb-tools env.
if ! command -v sbsign &>/dev/null || ! command -v mcopy &>/dev/null \
   || ! command -v mkfs.vfat &>/dev/null || ! command -v xorriso &>/dev/null; then
  [[ -z "${SIGN_ISO_BOOTSTRAPPED:-}" ]] \
    || die "signing tools still missing after nix shell bootstrap"
  exec env SIGN_ISO_BOOTSTRAPPED=1 nix shell "${REPO_ROOT}#sb-tools" -c "$0" "$@"
fi

# ── Arguments ────────────────────────────────────────────────────
OUT="" KEYDIR="${REPO_ROOT}/secrets/secureboot" SHIM_DIR="" ISO_IN=""
EXTRA_KEY="" EXTRA_CERT=""
SBCTL_DB="${SBCTL_DB:-/var/lib/sbctl/keys/db}"
while (( $# )); do
  case "$1" in
    -o)           OUT="$2"; shift 2 ;;
    -k)           KEYDIR="$2"; shift 2 ;;
    --shim)       SHIM_DIR="$2"; shift 2 ;;
    --extra-sign) EXTRA_KEY="$2"; EXTRA_CERT="$3"; shift 3 ;;
    --sbctl)      EXTRA_KEY="${SBCTL_DB}/db.key"; EXTRA_CERT="${SBCTL_DB}/db.pem"; shift ;;
    -*)           die "unknown option: $1" ;;
    *)            [[ -z "${ISO_IN}" ]] || die "only one input ISO allowed"
                  ISO_IN="$1"; shift ;;
  esac
done
[[ -n "${ISO_IN}" && -f "${ISO_IN}" ]] || die "input ISO not found: '${ISO_IN:-}'"
if [[ -z "${OUT}" ]]; then
  OUT="${REPO_ROOT}/result-iso-signed/$(basename "${ISO_IN}" .iso)-signed.iso"
fi
mkdir -p "$(dirname "${OUT}")"

if [[ -z "${SHIM_DIR}" ]]; then
  log "resolving Microsoft-signed shim (.#shim-signed)"
  SHIM_DIR="$(nix build "${REPO_ROOT}#shim-signed" --no-link --print-out-paths)"
fi
[[ -f "${SHIM_DIR}/shimx64.efi" && -f "${SHIM_DIR}/mmx64.efi" ]] \
  || die "shimx64.efi/mmx64.efi not found in ${SHIM_DIR}"

# ── Signing key: generate once, reuse forever ────────────────────
# Reuse is what keeps already-enrolled machines booting newly signed ISOs.
CERT_BASENAME="tokyonight-dots-mok.cer"
if [[ ! -f "${KEYDIR}/MOK.key" ]]; then
  log "generating MOK signing key in ${KEYDIR} (first run)"
  mkdir -p "${KEYDIR}"
  (
    umask 077
    openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=tokyonight-dots Secure Boot MOK/" \
      -keyout "${KEYDIR}/MOK.key" -out "${KEYDIR}/MOK.crt" 2>/dev/null
  )
  openssl x509 -in "${KEYDIR}/MOK.crt" -outform DER -out "${KEYDIR}/MOK.cer"
else
  log "reusing MOK signing key from ${KEYDIR}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── Optional cosign key (e.g. the sbctl db key) ──────────────────
# The private key may be root-owned (sbctl keeps 0700 dirs); read it in
# place via sudo, never copy it. The cert is public — copy it out so
# sbsign/sbverify can read it as us.
EXTRA_SUDO=""
if [[ -n "${EXTRA_KEY}" ]]; then
  [[ -f "${EXTRA_KEY}" ]] || die "cosign key not found: ${EXTRA_KEY}"
  if [[ ! -r "${EXTRA_KEY}" ]]; then
    command -v sudo &>/dev/null \
      || die "cosign key ${EXTRA_KEY} is unreadable and sudo is unavailable"
    EXTRA_SUDO="sudo"
    log "cosign key is root-owned — sudo will read it for the extra sbsign"
  fi
  if [[ ! -r "${EXTRA_CERT}" ]]; then
    ${EXTRA_SUDO} cat "${EXTRA_CERT}" > "${WORK}/extra.pem" 2>/dev/null \
      || die "cannot read cosign cert ${EXTRA_CERT}"
    EXTRA_CERT="${WORK}/extra.pem"
  fi
  log "cosigning with $(openssl x509 -in "${EXTRA_CERT}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
fi

# ── Pull the EFI pieces out of the unsigned ISO ──────────────────
log "extracting EFI boot files from $(basename "${ISO_IN}")"
xorriso -osirrox on -indev "${ISO_IN}" \
  -extract /boot/efi.img "${WORK}/efi.img" \
  -extract /EFI/BOOT/grub.cfg "${WORK}/grub.cfg" \
  -extract /EFI/BOOT/BOOTX64.EFI "${WORK}/grub-unsigned.efi" \
  &>/dev/null || die "extraction failed — is this a NixOS installer ISO?"
xorriso -osirrox on -indev "${ISO_IN}" \
  -extract /EFI/BOOT/refind_x64.efi "${WORK}/refind-unsigned.efi" \
  &>/dev/null || true
chmod -R u+w "${WORK}"

# ── Inject .sbat into GRUB (shim ≥15.6 refuses stage-2 without it) ─
# objcopy defaults the new section to VMA 0 (an unloadable PE), so place it
# explicitly after the last section, aligned to PE SectionAlignment (0x1000).
read -r last_size last_vma < <(objdump -h "${WORK}/grub-unsigned.efi" \
  | awk '$1 ~ /^[0-9]+$/ { size=$3; vma=$4 } END { print size, vma }')
sbat_vma=$(printf '0x%x' $(( (0x${last_vma} + 0x${last_size} + 0xfff) & ~0xfff )))
cat > "${WORK}/sbat.csv" <<'EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.tokyonight-dots,1,tokyonight-dots,grub,2.12,https://gitlab.com/tentypekmatus/tokyonight-dots
EOF
objcopy --add-section .sbat="${WORK}/sbat.csv" \
  --set-section-flags .sbat=contents,alloc,load,readonly,data \
  --change-section-address .sbat="${sbat_vma}" \
  "${WORK}/grub-unsigned.efi" "${WORK}/grubx64.unsigned.efi"
objdump -h "${WORK}/grubx64.unsigned.efi" | grep -q '\.sbat' \
  || die ".sbat section missing after objcopy"

# ── Sign GRUB, rEFInd and every kernel referenced by grub.cfg ────
# Primary signature is always the MOK. When a cosign key is given, sbsign
# APPENDS a second signature (the PE keeps both); either trusted cert then
# satisfies shim/firmware independently.
sign() {
  local in="$1" out="$2"
  sbsign --key "${KEYDIR}/MOK.key" --cert "${KEYDIR}/MOK.crt" \
    --output "${out}" "${in}" 2>/dev/null
  sbverify --cert "${KEYDIR}/MOK.crt" "${out}" >/dev/null \
    || die "sbverify (MOK) failed for ${out}"
  if [[ -n "${EXTRA_KEY}" ]]; then
    ${EXTRA_SUDO} sbsign --key "${EXTRA_KEY}" --cert "${EXTRA_CERT}" \
      --output "${out}.x" "${out}" 2>/dev/null || die "cosign failed for ${out}"
    [[ -n "${EXTRA_SUDO}" ]] \
      && ${EXTRA_SUDO} chown "$(id -u):$(id -g)" "${out}.x"
    mv "${out}.x" "${out}"
    sbverify --cert "${EXTRA_CERT}" "${out}" >/dev/null \
      || die "sbverify (cosign) failed for ${out}"
    sbverify --cert "${KEYDIR}/MOK.crt" "${out}" >/dev/null \
      || die "MOK signature lost after cosign for ${out}"
  fi
}
sign "${WORK}/grubx64.unsigned.efi" "${WORK}/grubx64.efi"
ok "signed grubx64.efi (with .sbat @ ${sbat_vma})"
if [[ -f "${WORK}/refind-unsigned.efi" ]]; then
  sign "${WORK}/refind-unsigned.efi" "${WORK}/refind_x64.efi"
  ok "signed refind_x64.efi"
fi

mapfile -t kernels < <(grep -Eo '/boot/[^ )]+/bzImage' "${WORK}/grub.cfg" \
  | sed 's|//*|/|g' | sort -u)
(( ${#kernels[@]} )) || die "no kernels found in grub.cfg"
map_args=()
i=0
for k in "${kernels[@]}"; do
  xorriso -osirrox on -indev "${ISO_IN}" \
    -extract "${k}" "${WORK}/bzImage.${i}" &>/dev/null \
    || die "kernel extraction failed: ${k}"
  chmod u+w "${WORK}/bzImage.${i}"
  sign "${WORK}/bzImage.${i}" "${WORK}/bzImage.${i}.signed"
  ok "signed kernel ${k}"
  map_args+=( -map "${WORK}/bzImage.${i}.signed" "${k}" )
  i=$(( i + 1 ))
done

# ── Rebuild the El Torito ESP image with the shim layout ─────────
# grub.cfg does `search --fs-uuid 1234-5678`, so the serial must survive.
log "rebuilding efi.img (shim + MokManager + signed GRUB)"
fatroot="${WORK}/fatroot"
mkdir -p "${fatroot}"
mcopy -sn -i "${WORK}/efi.img" ::/ "${fatroot}/" \
  || die "mcopy out of original efi.img failed"
chmod -R u+w "${fatroot}"
install -m444 "${SHIM_DIR}/shimx64.efi" "${fatroot}/EFI/BOOT/BOOTX64.EFI"
install -m444 "${SHIM_DIR}/mmx64.efi"   "${fatroot}/EFI/BOOT/mmx64.efi"
install -m444 "${WORK}/grubx64.efi"     "${fatroot}/EFI/BOOT/grubx64.efi"
install -m444 "${KEYDIR}/MOK.cer"       "${fatroot}/EFI/BOOT/${CERT_BASENAME}"
[[ -f "${WORK}/refind_x64.efi" ]] \
  && install -m444 "${WORK}/refind_x64.efi" "${fatroot}/EFI/BOOT/refind_x64.efi"

# Same sizing as nixpkgs iso-image.nix: 110% of usage, rounded up to 1 MiB.
usage_size=$(( $(du -sb --apparent-size "${fatroot}" | cut -f1) * 110 / 100 ))
img_size=$(( (usage_size / 1048576 + 1) * 1048576 ))
rm -f "${WORK}/efi.img.new"
truncate -s "${img_size}" "${WORK}/efi.img.new"
mkfs.vfat --invariant -i 12345678 -n EFIBOOT "${WORK}/efi.img.new" >/dev/null
(
  cd "${fatroot}"
  find . -mindepth 1 -type d | sort | while read -r d; do
    mmd -i "${WORK}/efi.img.new" "::/${d#./}"
  done
  find . -type f | sort | while read -r f; do
    mcopy -pm -i "${WORK}/efi.img.new" "${f}" "::/${f#./}"
  done
)
fsck.vfat -vn "${WORK}/efi.img.new" >/dev/null || die "fsck.vfat failed"

# ── Repack: replay the boot record, swap in the signed pieces ────
# `-boot_image any replay` re-emits El Torito (BIOS+UEFI), the isohybrid
# MBR and the GPT entry over the (grown, moved) efi.img.
log "repacking ISO (xorriso boot-record replay)"
refind_map=()
[[ -f "${WORK}/refind_x64.efi" ]] \
  && refind_map=( -map "${WORK}/refind_x64.efi" /EFI/BOOT/refind_x64.efi )
rm -f "${OUT}.tmp"
xorriso -indev "${ISO_IN}" -outdev "${OUT}.tmp" \
  -boot_image any replay \
  -overwrite nondir \
  -map "${WORK}/efi.img.new"        /boot/efi.img \
  -map "${SHIM_DIR}/shimx64.efi"    /EFI/BOOT/BOOTX64.EFI \
  -map "${WORK}/grubx64.efi"        /EFI/BOOT/grubx64.efi \
  -map "${SHIM_DIR}/mmx64.efi"      /EFI/BOOT/mmx64.efi \
  -map "${KEYDIR}/MOK.cer"          "/EFI/BOOT/${CERT_BASENAME}" \
  "${refind_map[@]}" \
  "${map_args[@]}" \
  &>"${WORK}/xorriso.log" || { cat "${WORK}/xorriso.log" >&2; die "xorriso repack failed"; }

# ── Structural self-check on the output ──────────────────────────
report="$(xorriso -indev "${OUT}.tmp" -report_el_torito plain \
  -report_system_area plain 2>/dev/null)"
grep -q 'El Torito boot img.*BIOS' <<<"${report}" || die "BIOS El Torito entry lost"
grep -q 'El Torito boot img.*UEFI' <<<"${report}" || die "UEFI El Torito entry lost"
grep -q 'GPT partition name.*EFI' <<<"${report}" \
  || grep -q 'MBR partition table' <<<"${report}" \
  || die "isohybrid MBR/GPT partition data lost"
mv "${OUT}.tmp" "${OUT}"

ok "signed ISO: ${OUT} ($(du -h "${OUT}" | cut -f1))"
log "MOK cert: $(openssl x509 -in "${KEYDIR}/MOK.crt" -noout -fingerprint -sha256 \
  | cut -d= -f2)"
if [[ -n "${EXTRA_KEY}" ]]; then
  log "cosigned: machines whose Secure Boot db trusts that key boot with no prompt"
fi
log "factory Secure Boot machines: enroll /EFI/BOOT/${CERT_BASENAME} once via MokManager"
