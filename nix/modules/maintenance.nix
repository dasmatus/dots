# Background maintenance — replaces the Gentoo reseal pipeline
# (portage-sync.timer + gentoo-reseal.service + systemd-sysupdate A/B):
# autoUpgrade with operation="boot" builds the new generation in the
# background and activates it on the next reboot, like the reseal design.
#
# Upgrades MUST build from the on-target flake copy (/etc/dots) — it carries
# the settings.nix the installer wrote. Building from the GitLab remote would
# eval the committed placeholder settings and revert the hostname/user on the
# next reboot. The preStart refreshes the lock file so "daily" actually moves.
{ config, variant, ... }:
{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  system.autoUpgrade = {
    enable = true;
    flake = "/etc/dots#tokyonight-${variant}";
    dates = "daily";
    operation = "boot";
    allowReboot = false;
  };

  systemd.services.nixos-upgrade.preStart = ''
    ${config.nix.package}/bin/nix flake update --flake /etc/dots
  '';
}
