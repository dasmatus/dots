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
  networking.hostName = settings.hostname;

  # Unfree is opt-in per package; claude-code comes in via home-manager
  # (useGlobalPkgs, so the system nixpkgs config applies).
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "claude-code"
      # no upstream license → nixpkgs marks it unfree
      "presence.nvim"
    ];

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

  # GnuPG smartcard support — matches the retired Gentoo package.use gpg file
  # (app-crypt/gnupg smartcard usb, gnutls pkcs11; git history). pinentry was
  # built without gtk there; GNOME is the desktop now, so use pinentry-gnome3.
  services.pcscd.enable = true;
  hardware.gpgSmartcards.enable = true;
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-gnome3;
  };

  system.stateVersion = "26.05";
}
