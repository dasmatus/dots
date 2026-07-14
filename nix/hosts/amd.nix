# AMD variant — mirrors "Gentoo configuration/make.conf.amd"
# (VIDEO_CARDS="amdgpu radeonsi", znver2). Clang/LTO toolchain choices have no
# NixOS equivalent worth losing the binary cache over.
{ ... }:
{
  hardware.cpu.amd.updateMicrocode = true;
  hardware.graphics.enable = true;
  boot.initrd.kernelModules = [ "amdgpu" ];
  boot.kernelParams = [ "amd_pstate=active" ];
}
