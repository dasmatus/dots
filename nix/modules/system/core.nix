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
  # boot.kernelPackages moved to nix/modules/system/kernel.nix (Phase A,
  # docs/superpowers/specs/2026-09-08-hardening-design.md), gated on
  # dots.kernel.harden.
  services.systemd-lock-handler.enable = true;
  services.displayManager.defaultSession = "hyprland-uwsm";
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
      # Anthropic's desktop app, repackaged from their .deb because that is
      # the only channel they publish (nix/packages/claude-desktop.nix).
      "claude-desktop"
      # proprietary Electron app, ex-flatpak (nix/home/base/pkgs.nix)
      "obsidian"
      # no upstream license → nixpkgs marks it unfree
      "presence.nvim"
      # proprietary driver + settings tool, pulled in when nix/system/hosts.nix
      # detects an NVIDIA card in the facter report
      "nvidia-x11"
      "nvidia-settings"
      "vscode-extension-fill-labs-dependi"
      "cisco-packet-tracer"
      # Steam client + its unfree redistributable deps. `programs.steam.enable`
      # (nix/modules/desktop/steam.nix) puts `steam` (an FHS wrapper, pname "steam")
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
    # No Hyprland-specific substituter is needed: the compositor now comes
    # from nixpkgs (programs.hyprland default package, see
    # nix/modules/desktop/desktop.nix), so it and its deps are Hydra-built
    # and substituted from cache.nixos.org already. The earlier
    # hyprland.cachix.org substituter existed for a pinned Hyprland flake
    # input, which is gone — and which built from source anyway once Cachix
    # evicted the old tagged prebuilt — an eviction policy we did not
    # control, because it was someone else's cache.
    #
    # The extra substituter below is ours, not a third party's: the
    # matusdasdots Cachix cache that CI populates (.forgejo/workflows/ci.yml)
    # for this repo's own closures. Verified against the pinned nixpkgs
    # (567a49d1913ce81ac6e9582e3553dd90a955875f,
    # nixos/modules/config/nix.nix): neither `substituters` nor
    # `trusted-public-keys` carries an mkOption default; the module instead
    # injects `substituters = mkAfter [ "https://cache.nixos.org/" ]` at
    # config level. So this plain definition list-merges rather than
    # clobbering, and cache.nixos.org still applies, appended after ours.
    substituters = [ "https://matusdasdots.cachix.org" ];
    trusted-public-keys = [
      "matusdasdots.cachix.org-1:iTh1MBvMxZLOGy2d4/piAOjD6MbInPpUliYFhxKG258="
    ];
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
