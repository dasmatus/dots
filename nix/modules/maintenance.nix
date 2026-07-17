# Background maintenance — replaces the retired Gentoo reseal pipeline
# (portage-sync.timer + gentoo-reseal.service + systemd-sysupdate A/B;
# git history):
# autoUpgrade with operation="boot" builds the new generation in the
# background and activates it on the next reboot, like the reseal design.
#
# Upgrades MUST build from the user's clone at ~/Dokumente/gitlab/personal/
# dots — it carries the installer-written settings.nix/facter.json restored
# by the dots-clone Home Manager user service (nix/home/dots-repo.nix).
# Building from the GitLab remote instead would eval the committed
# placeholder settings and revert the hostname/user on the next reboot. The
# nixos-upgrade unit is gated on that clone existing (ConditionPathExists);
# the preStart refreshes the lock file so "daily" actually moves, and since
# nixos-upgrade runs as root, flake.lock is chowned back to the user
# afterwards so the user's own git workflow (commits, pushes) keeps working.
{
  config,
  pkgs,
  settings,
  ...
}:
let
  dotsRepo = "/home/${settings.username}/Dokumente/gitlab/personal/dots";
in
{
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 0d";
  };
  nix.optimise.automatic = true;

  # root's nixos-rebuild needs to trust the user-owned repo (nix's libgit2
  # fetcher plus any git CLI invocation) since dotsRepo lives under /home.
  programs.git = {
    enable = true;
    config.safe.directory = [ dotsRepo ];
  };

  system.autoUpgrade = {
    enable = true;
    flake = "${dotsRepo}#tokyonight";
    dates = "daily";
    operation = "boot";
    allowReboot = false;
  };

  systemd.services.nixos-upgrade = {
    unitConfig.ConditionPathExists = "${dotsRepo}/flake.nix";
    preStart = ''
      ${config.nix.package}/bin/nix flake update --flake ${dotsRepo}
      ${pkgs.coreutils}/bin/chown ${settings.username}: ${dotsRepo}/flake.lock
    '';
  };
}
