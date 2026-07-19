# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Locale/timezone are the user's picks (de_DE.UTF-8, Europe/Bratislava);
# the package set matches the retired Gentoo installer's SYSTEM_PACKAGES
# (git history).
{
  pkgs,
  lib,
  settings,
  ...
}:
{
  security.pam.services.login.enableGnomeKeyring = true;
  networking.hostName = settings.hostname;

  # Unfree is opt-in per package; claude-code comes in via home-manager
  # (useGlobalPkgs, so the system nixpkgs config applies).
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
      # proprietary Electron app, ex-flatpak (nix/home/pkgs.nix)
      "obsidian"
      # no upstream license → nixpkgs marks it unfree
      "presence.nvim"
      # proprietary driver + settings tool, pulled in when nix/hosts.nix
      # detects an NVIDIA card in the facter report
      "nvidia-x11"
      "nvidia-settings"
    ];

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
  };

  time.timeZone = "Europe/Bratislava";
  i18n.defaultLocale = "de_DE.UTF-8";

  environment.systemPackages = with pkgs; [
    git
    bat
    eza
    btrfs-progs
    gnupg
    glab
    curl
    file
    tpm2-tools
  ];

  programs.fish.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-gnome3;
  };

  system.stateVersion = "26.05";
}
