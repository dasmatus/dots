# Intel variant — mirrors "Gentoo configuration/make.conf.intel"
# (VIDEO_CARDS="intel i915"). CPU tuning (-march=skylake) has no NixOS
# equivalent worth losing the binary cache over.
{ ... }:
{
  hardware.cpu.intel.updateMicrocode = true;
  hardware.graphics.enable = true;
  boot.initrd.kernelModules = [ "i915" ];
}
