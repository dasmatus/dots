# Background maintenance — replaces the retired Gentoo reseal pipeline
# (portage-sync.timer + gentoo-reseal.service + systemd-sysupdate A/B;
# git history):
# autoUpgrade with operation="boot" builds the new generation in the
# background and activates it on the next reboot, like the reseal design.
#
# Upgrades MUST build from the user's clone at ~/Dokumente/gitlab/personal/
# dots — it carries the installer-written settings.nix/data/facter.json restored
# by the dots-clone Home Manager user service (nix/home/base/dots-repo.nix).
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
    # Only these two: this unit runs as root, writes into $HOME (the
    # clone) and needs to build a boot generation and touch /boot, so
    # ProtectSystem=strict/ProtectHome and friends need a precise
    # ReadWritePaths computed from settings.username — real, non-mechanical
    # work tracked separately, not a drive-by addition here (see
    # research-units.md §4 item 6). These two are safe regardless: neither
    # `nix flake update` nor the nixos-rebuild machinery this unit drives
    # has a legitimate reason to gain privilege via a setuid/setgid exec,
    # or to create a new setuid/setgid file.
    serviceConfig = {
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
    };
  };

  # Lynis PKGS-7398 asks for a package audit tool. The generic answer (a distro
  # package auditor) has nothing to read on NixOS, so this uses vulnix, which
  # matches store paths in the running system closure against NVD instead of
  # against a package database that does not exist here.
  #
  # Weekly rather than daily, and it only reports: nothing here upgrades or
  # reboots on a CVE. Read it with `journalctl -u vulnix`. Exit status 2 means
  # vulnix found something, which systemd would otherwise call a failed unit,
  # so the status is remapped to success and the finding lives in the log.
  systemd.services.vulnix = {
    description = "Scan the system closure for known vulnerabilities";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.vulnix}/bin/vulnix --system";
      SuccessExitStatus = [
        0
        2
      ];
      # Read-only, unprivileged, no network beyond the NVD fetch it does itself.
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CacheDirectory = "vulnix";
    };
  };

  systemd.timers.vulnix = {
    description = "Weekly vulnerability scan of the system closure";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
}
