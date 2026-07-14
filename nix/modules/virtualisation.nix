# libvirt/QEMU stack — parity with the konkrit VM prerequisites installed by
# installer/chroot_system.py (libvirt, qemu, virt-manager, OVMF, swtpm).
{ ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    # OVMF images ship with QEMU by default on current nixpkgs.
    qemu.swtpm.enable = true;
  };
  programs.virt-manager.enable = true;
}
