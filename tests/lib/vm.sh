#!/usr/bin/env bash
# ================================================================
#  tests/lib/vm.sh — libvirt VM lifecycle helpers for the harness
#
#  Boots the flake's LiveISO (nix build .#iso) through OVMF (genuine UEFI)
#  with an emulated TPM 2.0 (swtpm). Output is captured on the serial log.
#
#  Public functions:
#    vm_check_host           — verify virsh/qemu/swtpm/xorriso/OVMF present
#    vm_make_disk <path> <size>
#    vm_define <name> ...    — render domain.xml.tmpl and `virsh define`
#    vm_start  <name>
#    vm_destroy <name>       — destroy + undefine + drop nvram
#    vm_serial_log <name>    — echo the serial-log path
# ================================================================
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

# qemu:///session runs qemu AS THE INVOKING USER, so the serial log + 9p-shared
# files are owned by us (no root, no libvirt group, no security-driver relabel).
# /dev/kvm is world-accessible here and user-mode networking needs no host setup.
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
