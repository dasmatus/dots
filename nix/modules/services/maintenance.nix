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
    # Was 0d. Phase A (docs/superpowers/specs/2026-09-08-hardening-design.md)
    # made this collapse dangerous rather than merely wasteful:
    # `--delete-older-than 0d` deletes every generation older than "just
    # now" except one, which left `maxGenerations` below (boot.nix) close to
    # decorative even before the kernel went from-source. A from-source
    # kernel with no binary cache, going straight to CFI-enforcing, cannot
    # afford GC pruning its own fallback generations before a human notices
    # a regression. 30d keeps roughly a month of generations on disk,
    # recoverable by hand (nix-env --switch-generation + re-run the Limine
    # installer) even after they roll off the visible boot menu.
    options = "--delete-older-than 30d";
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
    # Phase B, ruling R6: the ProtectSystem=strict half of the searxng-keygen
    # set the earlier comment deferred, now computed rather than guessed.
    #
    # One correction to the deferred comment above, worth stating plainly:
    # this unit does NOT write into "$HOME (the clone)" as one and the same
    # path. `system.autoUpgrade` (nixpkgs' auto-upgrade.nix) hardcodes this
    # unit's own `HOME=/root` regardless of who owns the clone — it is not
    # `settings.username`'s home. The clone this unit actually writes into
    # (`dotsRepo`, above) lives under `/home/${settings.username}/...`, a
    # completely different path from the process's own $HOME. Both need a
    # ReadWritePaths entry, for different reasons:
    #   - `dotsRepo`: where `preStart`'s `nix flake update` rewrites
    #     flake.lock, and where the subsequent `chown` runs.
    #   - `/root`: this process's own $HOME, where nix's git/tarball fetcher
    #     cache (`~/.cache/nix`) lands for the flake-input fetches both
    #     `nix flake update` and the `nixos-rebuild` it triggers perform.
    #     Not verified by a boot-tested run — nix has been known to degrade
    #     gracefully without a writable cache dir in some code paths and not
    #     others — so if `nixos-upgrade.service` starts failing after this
    #     lands, this is the first place to look; widening back to
    #     `ProtectHome = false` is the fallback, not silently dropping
    #     ProtectSystem too.
    #   - `/boot`: `switch-to-configuration boot` (triggered by `operation =
    #     "boot"` above) installs the new generation's entry via
    #     nix/modules/system/limine-install.nix, which writes config and
    #     kernel/initrd files onto the mounted ESP. `canTouchEfiVariables =
    #     false` (nix/modules/system/boot.nix) means it never touches
    #     `/sys/firmware/efi/efivars`, which is what keeps
    #     ProtectKernelTunables safe to add below — an EFI-variable-writing
    #     bootloader install would need that path excluded too.
    #   - `/nix/var/nix/profiles` and `/nix/var/nix/gcroots`: registering the
    #     new system generation (the `system` profile symlink + its GC root)
    #     is done by the `nix`/`nixos-rebuild` client process itself, not
    #     handed off to nix-daemon the way store realisation is — `/nix/store`
    #     is read-only at the OS level regardless of ProtectSystem and needs
    #     no carve-out, but the profile/gcroots trees under `/nix/var` are
    #     ordinary writable directories that `ProtectSystem = "strict"` would
    #     otherwise lock.
    #
    # NOT added: CapabilityBoundingSet. This unit runs fully as root and its
    # `preStart` alone needs CAP_CHOWN; the bootloader installer it triggers
    # is arbitrary Python (limine-install.py) whose own privilege needs can
    # change across a nixpkgs bump. Enumerating a minimal set for both today
    # and risks a silent, hard-to-diagnose failure the next time either
    # changes — matching the same "leave it alone" call made for
    # NetworkManager above, for the analogous reason.
    #
    # ProtectKernelTunables/Modules, ProtectControlGroups, RestrictNamespaces,
    # LockPersonality, MemoryDenyWriteExecute, PrivateDevices: nothing this
    # unit does needs a kernel-tunable write, a module load, a new namespace,
    # an ABI personality switch, a W^X page, or a real device node, so all of
    # searxng.nix's set applies unmodified here.
    serviceConfig = {
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [
        dotsRepo
        "/root"
        "/boot"
        "/nix/var/nix/profiles"
        "/nix/var/nix/gcroots"
      ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
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
