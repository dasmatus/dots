# Secure Boot via lanzaboote — ON by default. As a side effect this also
# builds Unified Kernel Images (UKIs) by default: lanzaboote builds a signed
# UKI per generation and installs it to the ESP, replacing plain systemd-boot
# (which it disables with mkForce below). nix/modules/boot.nix keeps the
# plain systemd-boot config for the fallback case where this flag is turned
# off.
#
# Although the flag is on by default, the firmware still has to *trust* the
# signing keys before a signed UKI will boot — this is a one-time, post-install
# enrollment because key enrollment needs the firmware in Setup Mode:
#   sudo sbctl create-keys
#   (reboot into firmware, enable Setup Mode)
#   sudo sbctl enroll-keys --microsoft
#   nixos-rebuild switch
# Until that dance is done, either keep the firmware's Secure Boot off (the
# signed UKI boots unsigned-verified... i.e. unverified, so fine) or set
# dots.secureboot.enable = false to fall back to plain systemd-boot. The
# retired Gentoo installer generated db keys at install time (git history).
{
  lib,
  pkgs,
  config,
  ...
}:
{
  options.dots.secureboot.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Secure Boot signing via lanzaboote (and thus UKI building).";
  };

  config = lib.mkIf config.dots.secureboot.enable {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };
    environment.systemPackages = [ pkgs.sbctl ];
  };
}
