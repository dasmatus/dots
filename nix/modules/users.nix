# The primary user — replaces the Gentoo first-boot `homectl create` flow;
# the username comes from nix/settings.nix (written by the installer TUI).
# mutableUsers stays true so the passwords set by the installer via chpasswd
# survive rebuilds.
{ pkgs, settings, ... }:
{
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
    users.${settings.username} = import ../home;
  };
}
