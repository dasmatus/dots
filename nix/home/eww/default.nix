# eww widget configuration. Keeps the rofi drun app launcher (see
# nix/home/hyprland.nix) and replaces only the rofi first-login keybind
# cheatsheet with a native eww window. Rofi is also kept for the file manager
# (rofi-files.sh) and the power menu.
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
