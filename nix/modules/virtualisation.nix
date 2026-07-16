# libvirt/QEMU stack — matches the VM prerequisites installed by the retired
# konkrit firstboot catalog (Gentoo era, git history): libvirt, qemu,
# virt-manager, OVMF, swtpm.
{ ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    # OVMF images ship with QEMU by default on current nixpkgs.
    qemu.swtpm.enable = true;
  };
  programs.virt-manager.enable = true;
}
