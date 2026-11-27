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
    #
    # Where the real trust boundary sits: `matusdasdots` uses a
    # Cachix-managed signing key (the API returns `publicSigningKeys`, i.e.
    # Cachix holds the private half and signs server-side on every push), and
    # `require-sigs` stays `true` on both this config and the ISO's
    # (nix/system/iso.nix; verified by eval), with `trusted-substituters`
    # left at `[]`. `require-sigs` therefore stops a hostile CDN or a MITM
    # from swapping in an unsigned path over this substituter's own
    # connection — but it does nothing against whoever holds CACHIX_KEY:
    # that token can get arbitrary store paths signed by the cache and then
    # substituted here, to run as root on tokyonight and on every machine
    # installed from the LiveISO. That is a normal, acceptable tradeoff for
    # a cache one controls — CACHIX_KEY is scoped to this repo's own CI — but
    # it is a different axis of trust than `require-sigs` is usually read as
    # buying, and worth naming plainly rather than leaving a reader to assume
    # the wrong one.
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
