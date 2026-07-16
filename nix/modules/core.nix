# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Parity: installer/chroot_base.py (locale de_DE.UTF-8, BA UTC) and the
# always-present parts of SYSTEM_PACKAGES (installer/chroot_system.py).
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
    fastfetch
    gnupg
    glab
    curl
    file
    tpm2-tools
  ];

  programs.fish.enable = true;

  # GnuPG smartcard support — parity with the Gentoo package.use gpg file
  # (app-crypt/gnupg smartcard usb, gnutls pkcs11). pinentry was built
  # without gtk on Gentoo; GNOME is the desktop now, so use pinentry-gnome3.
  services.pcscd.enable = true;
  hardware.gpgSmartcards.enable = true;
  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-gnome3;
  };

  system.stateVersion = "26.05";
}
