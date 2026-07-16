# Intel variant — mirrors the retired "Gentoo configuration/make.conf.intel"
# (VIDEO_CARDS="intel i915"; git history). CPU tuning (-march=skylake) has no
# NixOS equivalent worth losing the binary cache over.
{ ... }:
{
  hardware.cpu.intel.updateMicrocode = true;
  hardware.graphics.enable = true;
  boot.initrd.kernelModules = [ "i915" ];
}
