# Secure Boot via lanzaboote — OFF by default. The Gentoo installer generated
# db keys at install time; on NixOS this is a post-install opt-in because key
# enrollment needs the firmware in Setup Mode:
#   sudo sbctl create-keys
#   (reboot into firmware, enable Setup Mode)
#   sudo sbctl enroll-keys --microsoft
#   set dots.secureboot.enable = true; then nixos-rebuild switch
{
  lib,
  pkgs,
  config,
  ...
}:
{
  options.dots.secureboot.enable = lib.mkEnableOption "Secure Boot signing via lanzaboote";

  config = lib.mkIf config.dots.secureboot.enable {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };
    environment.systemPackages = [ pkgs.sbctl ];
  };
}
