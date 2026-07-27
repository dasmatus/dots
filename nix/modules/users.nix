# The primary user — replaces the retired Gentoo first-boot "homectl create"
# flow (git history); the username comes from nix/settings.nix (written by
# the installer TUI).
# mutableUsers stays true so the passwords set by the installer via chpasswd
# survive rebuilds.
{
  pkgs,
  settings,
  inputs,
  aipageFirefox,
  aipageChrome,
  wallpaperTui,
  hyprmon,
  ...
}:
{
  environment.pathsToLink = [
    "/share/applications"
    "/share/xdg-desktop-portal"
  ];
  users.mutableUsers = true;
  users.users.${settings.username} = {
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [
      "wheel"
      "audio"
      "video"
      "input"
      "networkmanager"
      "libvirtd"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # home modules need flake inputs too (nixvim module, haumea lib), plus
    # the in-flake aipage dists consumed by nix/home/{librewolf,brave}.nix
    # and the in-flake packages consumed across nix/home.
    # `settings` is passed so nix/home/git.nix can read the installer-collected
    # git identity (settings.gitName / settings.gitEmail); the desktop choice
    # in settings.desktop is NOT gated on the HM side — only the system-level
    # desktop block in nix/modules/desktop.nix reads it.
    extraSpecialArgs = {
      inherit
        inputs
        settings
        aipageFirefox
        aipageChrome
        wallpaperTui
        hyprmon
        ;
    };
    sharedModules = [ inputs.nixvim.homeModules.nixvim ];
    users.${settings.username} = import ../home;
  };
}
