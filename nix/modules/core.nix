# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Locale/timezone come from nix/defaults.nix (settings.timezone, settings.locale);
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
  programs.gamemode = {
    enable = true;
    enableRenice = true;
  };
  services.fwupd.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
  networking.hostName = config.dots.hostname;
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
      # proprietary Electron app, ex-flatpak (nix/home/pkgs.nix)
      "obsidian"
      # no upstream license → nixpkgs marks it unfree
      "presence.nvim"
      # proprietary driver + settings tool, pulled in when nix/hosts.nix
      # detects an NVIDIA card in the facter report
      "nvidia-x11"
      "nvidia-settings"
      "vscode-extension-fill-labs-dependi"
      # Steam client + its unfree redistributable deps. `programs.steam.enable`
      # (nix/modules/steam.nix) puts `steam` (an FHS wrapper, pname "steam")
      # into systemPackages, which pulls `steam-unwrapped` — the actual
      # unfree client binary (unfreeRedistributable, pname "steam-unwrapped").
      # `steamcmd` is the other unfree redistributable in the family (the
      # headless SteamCMD server tool). CI never exercises these: the
      # committed {} facter stub leaves graphics_card empty, so
      # hasDesktopGpu=false and the steam module's mkIf stays off — but a
      # real GPU machine (or dots.steam.enable=true override) turns it on,
      # and without these entries the rebuild refuses steam-unwrapped.
      # lib.getName covers both x86_64 and i686 (multiArch) variants: they
      # share the same pname. Free companions (steam-run/steam-tui MIT,
      # steamworks BSD2, protontricks GPL) need no entry.
      "steam"
      "steam-unwrapped"
      "steamcmd"
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
    # The Hyprland flake input (github:hyprwm/Hyprland?ref=v0.55.0 in
    # flake.nix) isn't built by Hydra, so the compositor and its deps
    # (udis86, aquamarine, hyprlang, …) are absent from cache.nixos.org and
    # nixos-rebuild falls back to compiling them from source. The Hyprland
    # Cachix binary cache holds the matching prebuilt store paths; pinning
    # its public key here (verified against https://wiki.hypr.land/Nix/Cachix/)
    # lets nix substitute them instead. `extra-*` appends to the default
    # cache.nixos.org substituter rather than replacing it, so the rest of
    # the closure still comes from the canonical cache.
    extra-substituters = [ "https://hyprland.cachix.org" ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
    ];
  };

  time.timeZone = settings.timezone;
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
