# eww widget configuration. Replaces the rofi drun app launcher and the rofi
# first-login keybind cheatsheet with native eww windows. Rofi is kept for the
# file manager (rofi-files.sh) and the power menu.
{ pkgs, ... }:
{
  home.packages = [
    pkgs.eww
    pkgs.jq
    pkgs.dex
  ];

  xdg.configFile = {
    "eww/eww.yuck".source = ./eww.yuck;
    "eww/eww.scss".source = ./eww.scss;

    "eww/scripts/list-apps.sh" = {
      source = ./scripts/list-apps.sh;
      executable = true;
    };
    "eww/scripts/launcher.sh" = {
      source = ./scripts/launcher.sh;
      executable = true;
    };
    "eww/scripts/keybinds.sh" = {
      source = ./scripts/keybinds.sh;
      executable = true;
    };
  };
}
