# eww widget configuration — only the first-login keybind cheatsheet window
# (nix/home/keybinds.nix data, SUPER+/ to re-open). The app launcher and power
# menu are beamenu (nix/home/beamenu.nix); the file browser is Nautilus.
{ pkgs, ... }:
{
  home.packages = [
    pkgs.eww
    pkgs.jq
  ];

  xdg.configFile = {
    "eww/eww.yuck".source = ./eww.yuck;
    "eww/eww.scss".source = ./eww.scss;

    "eww/scripts/keybinds.sh" = {
      source = ./scripts/keybinds.sh;
      executable = true;
    };
  };
}
