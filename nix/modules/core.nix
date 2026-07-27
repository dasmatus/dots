# Base system: nix daemon settings, locale, timezone, core CLI tools.
# Locale/timezone come from nix/defaults.nix (settings.timezone, settings.locale);
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
    # CUDA runtime: ollama-cuda (nix/hosts.nix, gated on hasNvidia) pulls
    # cuda_cudart / libcublas / cudnn / libnvjitlink / ... — a dozen-plus
    # unfree redistributables whose exact set shifts every nixpkgs bump, so
    # hand-maintaining them here is fragile. nixpkgs ships a curated
    # pkg→bool predicate that covers exactly the unfree CUDA packages (and
    # free ones — it's only consulted for unfree pkgs), so OR-ing it in adds
    # CUDA surgically instead of a blanket allowUnfree. NOT solved via
    # NIXPKGS_ALLOW_UNFREE on the installer's `nixos-install`: flake eval is
    # pure, so builtins.getEnv is invisible there, and that env var sets
    # blanket allowUnfree (every unfree package) + is non-durable across
    # rebuilds. Eval-safe: pkgs._cuda.lib.allowUnfreeCudaPredicate exists on
    # the pinned nixpkgs (verified).
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
      "steam"
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
