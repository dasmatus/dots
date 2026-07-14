# Background maintenance — replaces the Gentoo reseal pipeline
# (portage-sync.timer + gentoo-reseal.service + systemd-sysupdate A/B):
# autoUpgrade with operation="boot" builds the new generation in the
# background and activates it on the next reboot, like the reseal design.
{ variant, ... }:
{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  system.autoUpgrade = {
    enable = true;
    flake = "gitlab:TenTypekMatus/tokyonight-dots#tokyonight-${variant}";
    dates = "daily";
    operation = "boot";
    allowReboot = false;
  };
}
