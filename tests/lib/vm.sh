#!/usr/bin/env bash
# ================================================================
#  tests/lib/vm.sh — libvirt VM lifecycle helpers for the harness
#
#  Boots the SystemRescue live ISO through OVMF (genuine UEFI — install.sh
#  requires /sys/firmware/efi) with an emulated TPM 2.0 (swtpm). The ISO is
#  remastered once so its GRUB entries carry `console=ttyS0` + SystemRescue
#  autorun, and an `/autorun` script is injected that mounts the 9p-shared repo
#  and execs the guest runner. Installer output is captured on the serial log.
#
#  Public functions:
#    vm_check_host           — verify virsh/qemu/swtpm/xorriso/OVMF present
#    vm_fetch_iso            — download + cache + remaster the SystemRescue ISO
#    vm_make_disk <path> <size>
#    vm_define <name> ...    — render domain.xml.tmpl and `virsh define`
#    vm_start  <name>
#    vm_destroy <name>       — destroy + undefine + drop nvram
#    vm_serial_log <name>    — echo the serial-log path
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# SystemRescue is resolved DYNAMICALLY from SourceForge's best_release.json (the
# project's "current release" pointer) — never hardcode a version. Override with
# SYSRESCUE_ISO=<local path> or SYSRESCUE_URL=<explicit .iso url> to pin.
# qemu:///session runs qemu AS THE INVOKING USER, so the serial log + 9p-shared
# files are owned by us (no root, no libvirt group, no security-driver relabel).
# /dev/kvm is world-accessible here and user-mode networking needs no host setup.
: "${SYSRESCUE_SF_JSON:=https://sourceforge.net/projects/systemrescuecd/best_release.json}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///session}"
VIRSH=(virsh --connect "${LIBVIRT_URI}")

# ── Host capability check ────────────────────────────────────────
vm_check_host() {
  require_cmds virsh qemu-img qemu-system-x86_64 swtpm xorriso curl
  [[ -e /dev/kvm ]] || die "/dev/kvm missing — enable KVM (nested virt if this is itself a VM)"
  vm_ovmf_code >/dev/null || die "OVMF firmware not found (install edk2-ovmf)"
  "${VIRSH[@]}" version &>/dev/null \
    || die "cannot talk to libvirt at ${LIBVIRT_URI} — is libvirtd running and are you in the 'libvirt' group? (just setup)"
  # Guest networking uses user-mode (SLIRP) NAT — no host bridge/dnsmasq needed.
}

# Locate a read-only OVMF_CODE firmware image across distro layouts.
vm_ovmf_code() {
  local c
  for c in \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/OVMF/x64/OVMF_CODE.4m.fd \
    /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "${c}" ]] && { printf '%s\n' "${c}"; return 0; }
  done
  return 1
}

# Locate the matching OVMF_VARS template (the writable nvram seed).
vm_ovmf_vars() {
  local v
  for v in \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/OVMF/x64/OVMF_VARS.4m.fd \
    /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -f "${v}" ]] && { printf '%s\n' "${v}"; return 0; }
  done
  return 1
}

# Resolve the current SystemRescue download URL + filename (tab-separated) from
# the SourceForge best_release.json — no version hardcoded.
vm_resolve_iso() {
  require_cmds python3
  curl -fsSL "${SYSRESCUE_SF_JSON}" | python3 -c '
import sys, json
r = json.load(sys.stdin)["release"]
print(r["url"] + "\t" + r["filename"].rsplit("/", 1)[-1])' \
    || die "could not resolve the current SystemRescue release from ${SYSRESCUE_SF_JSON}"
}

# ── ISO fetch + remaster ─────────────────────────────────────────
# Downloads SystemRescue (cached) and produces a remastered copy that boots
# straight to a serial root shell running our autorun. Echoes the remastered
# ISO path.
vm_fetch_iso() {
  local url name base remastered
  if [[ -n "${SYSRESCUE_ISO:-}" ]]; then
    base="${SYSRESCUE_ISO}"; name="$(basename "${base}")"
  else
    if [[ -n "${SYSRESCUE_URL:-}" ]]; then
      url="${SYSRESCUE_URL}"; name="$(basename "${url%%\?*}")"
    else
      IFS=$'\t' read -r url name < <(vm_resolve_iso)
    fi
    base="${ISO_CACHE}/${name}"
    # Verify completeness against the mirror's Content-Length; re-fetch if partial.
    local want have=0
    want="$(curl -fsIL "${url}" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2} END{gsub(/\r/,"",v); print v}')"
    [[ -f "${base}" ]] && have="$(stat -c%s "${base}" 2>/dev/null || echo 0)"
    if [[ ! -f "${base}" || ( -n "${want}" && "${have}" -ne "${want}" ) ]]; then
      log "downloading ${name} → ${base} (resumable; want=${want:-?} have=${have})" >&2
      # -C -: resume a partial .part; --retry-all-errors: survive mirror resets.
      [[ -f "${base}" && -n "${want}" ]] && mv -f "${base}" "${base}.part"
      curl -fL -C - --retry 8 --retry-delay 3 --retry-all-errors \
        -o "${base}.part" "${url}" >&2
      mv "${base}.part" "${base}"
    fi
    have="$(stat -c%s "${base}")"
    [[ -z "${want}" || "${have}" -eq "${want}" ]] \
      || die "ISO still incomplete (${have}/${want} bytes) — mirror may be flaky, retry"
  fi
  remastered="${ISO_CACHE}/harness-${name}"

  if [[ ! -f "${remastered}" || "${base}" -nt "${remastered}" ]]; then
    log "remastering ISO (serial console + autorun)" >&2
    local work; work="$(mktemp -d "${ARTIFACTS}/isowork.XXXXXX")"
    # SystemRescue's UEFI menu lives in /boot/grub/grubsrcd.cfg; entries are
    # `linux …/vmlinuz archisobasedir=sysresccd …`. Append a serial console and
    # SystemRescue autorun opts (ar_nowait: don't wait for a keypress). Autorun
    # scripts go INSIDE the /autorun directory (named autorun) on the boot medium.
    cp "${TESTS_DIR}/guest/autorun" "${work}/autorun"
    xorriso -osirrox on -indev "${base}" \
      -extract /boot/grub/grubsrcd.cfg "${work}/grubsrcd.cfg" 2>/dev/null \
      || die "could not extract grubsrcd.cfg from ${base} (unexpected ISO layout)"
    sed -i -E 's|(archisobasedir=sysresccd)|\1 console=tty0 console=ttyS0,115200n8 ar_nowait=1 ar_ignorefail=1|' \
      "${work}/grubsrcd.cfg"
    xorriso -indev "${base}" -outdev "${remastered}" \
      -boot_image any replay \
      -map "${work}/grubsrcd.cfg" /boot/grub/grubsrcd.cfg \
      -map "${work}/autorun"      /autorun/autorun 2>/dev/null \
      || die "ISO remaster failed"
    rm -rf "${work}"
  fi
  printf '%s\n' "${remastered}"
}

# ── Disk ─────────────────────────────────────────────────────────
vm_make_disk() { qemu-img create -f qcow2 "$1" "$2" >/dev/null; }

# ── Domain define/start/destroy ──────────────────────────────────
# vm_define <name> <memMB> <vcpus> <disk> <iso> <serial> <sharedir>
vm_define() {
  local name="$1" mem="$2" vcpus="$3" disk="$4" iso="$5" serial="$6" sharedir="$7"
  local ovmf_code ovmf_vars_tmpl ovmf_vars xml
  ovmf_code="$(vm_ovmf_code)"
  ovmf_vars_tmpl="$(vm_ovmf_vars)" || die "OVMF_VARS template not found"
  ovmf_vars="${ARTIFACTS}/${name}_VARS.fd"
  xml="${ARTIFACTS}/${name}.xml"
  # rm (not truncate) first: a prior qemu:///system run may have left these files
  # root-owned; rm works because we own the directory. qemu recreates the serial
  # log as us on start.
  rm -f "${ovmf_vars}" "${serial}" "${xml}"
  cp "${ovmf_vars_tmpl}" "${ovmf_vars}"   # per-domain writable NVRAM copy
  sed -e "s|@NAME@|${name}|g" \
      -e "s|@MEMMB@|${mem}|g" \
      -e "s|@VCPUS@|${vcpus}|g" \
      -e "s|@OVMF_CODE@|${ovmf_code}|g" \
      -e "s|@OVMF_VARS@|${ovmf_vars}|g" \
      -e "s|@DISK@|${disk}|g" \
      -e "s|@ISO@|${iso}|g" \
      -e "s|@SERIAL@|${serial}|g" \
      -e "s|@SHAREDIR@|${sharedir}|g" \
      "${TESTS_DIR}/lib/domain.xml.tmpl" > "${xml}"
  "${VIRSH[@]}" define "${xml}" >/dev/null
}

vm_start()   { "${VIRSH[@]}" start "$1" >/dev/null; }

vm_destroy() {
  local name="$1"
  "${VIRSH[@]}" destroy  "${name}" &>/dev/null || true
  "${VIRSH[@]}" undefine "${name}" --nvram &>/dev/null || true
  rm -f "${ARTIFACTS}/${name}_VARS.fd" "${ARTIFACTS}/${name}.xml"
}
