# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Parity: installer/chroot_base.py (locale en_US.UTF-8, TZ UTC) and the
# always-present parts of SYSTEM_PACKAGES (installer/chroot_system.py).
{ pkgs, settings, ... }:
{
  networking.hostName = settings.hostname;

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

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  environment.systemPackages = with pkgs; [
    git
    neovim
    bat
    eza
    btrfs-progs
    fastfetch
    gnupg
    glab
    curl
    file
    tpm2-tools
  ];

  programs.fish.enable = true;

  system.stateVersion = "26.05";
}
