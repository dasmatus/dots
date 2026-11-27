# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Locale/timezone come from nix/system/defaults.nix (settings.timezone, settings.locale);
# the package set matches the retired Gentoo installer's SYSTEM_PACKAGES
# (git history).
{
  config,
  pkgs,
  lib,
  settings,
  ...
}:
{
  boot.kernelPackages = pkgs.linuxPackages_latest;
  services.systemd-lock-handler.enable = true;
  services.displayManager.defaultSession = "hyprland-uwsm";
  programs.gamemode = {
    enable = true;
    enableRenice = true;
  };
  services.fwupd.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  networking.hostName = config.dots.hostname;
  system.stateVersion = settings.system.stateVersion;
  system.nixos = {
    distroName = "dasmatus/dots";
    variantName = settings.hostname;
  };
  system.nixos-init.enable = true;
  system.etc.overlay = {
    enable = true;
    mutable = true;
  };
  # Unfree is opt-in per package; claude-code comes in via home-manager
  # (useGlobalPkgs, so the system nixpkgs config applies).
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
      "presence.nvim"
      "obsidian"
      "nvidia-x11"
      "nvidia-settings"
    ]
    || pkgs._cuda.lib.allowUnfreeCudaPredicate pkg;

  # vesktop 1.6.5 in the current nixpkgs pin still wraps electron-bin 40,
  # which went EOL with the 2026-07 flake.lock bump and is now refused by
  # default. Scoped to exactly that version so the next nixpkgs bump that
  # moves vesktop to a live electron drops the exception automatically.
  nixpkgs.config.permittedInsecurePackages = [ "electron-40.10.5" ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
    # Ship system components from cache.nixos.org only.
    substituters = [ "https://cache.nixos.org/" ];
  };

  # Automatic timezone-from-geolocation (localtimed + geoclue2) was here and
  # is gone (Phase C, docs/superpowers/specs/2026-09-08-hardening-design.md):
  # geoclue2 is a WiFi-SSID location daemon with no other consumer in this
  # repo — services.gammastep (nix/home/desktop/hyprland.nix) already runs
  # off hardcoded coordinates rather than geoclue2 — so it was pure attack
  # surface for one convenience (not having to set a timezone by hand while
  # traveling) this laptop's actual travel pattern rarely exercises.
  time.timeZone = lib.mkDefault settings.timezone;
  i18n.defaultLocale = settings.locale;

  environment.systemPackages = with pkgs; [
    git
    bat
    eza
    btrfs-progs
    gnupg
    curl
    file
    tpm2-tools
  ];

  programs.fish.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-gnome3;
  };
}
