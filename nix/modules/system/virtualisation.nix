# libvirt/QEMU stack — matches the VM prerequisites installed by the retired
# konkrit firstboot catalog (Gentoo era, git history): libvirt, qemu,
# virt-manager, OVMF, swtpm.
#
# Gated on dots.virtualisation.enable (nix/modules/dots.nix), default false,
# since Phase C of the hardening project
# (docs/superpowers/specs/2026-09-08-hardening-design.md): this used to be
# unconditional, which meant every install paid for a full VM host — a
# privileged libvirtd plus QEMU — whether or not it ever ran a VM.
# `nix run .#nix-smoke` drives QEMU directly rather than through libvirtd,
# so this gate does not touch that test harness.
{ config, lib, ... }:
lib.mkIf config.dots.virtualisation.enable {
  virtualisation.libvirtd = {
    enable = true;
    # OVMF images ship with QEMU by default on current nixpkgs.
    qemu.swtpm.enable = true;
  };
  programs.virt-manager.enable = true;
}
