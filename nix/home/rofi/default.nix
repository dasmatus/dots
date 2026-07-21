# programs.rofi port of files/rofi (deleted — see git history; the theme
# and file-manager script moved here via `git mv`). nixpkgs' rofi is 2.x,
# which merged the rofi-wayland fork upstream, so no override is needed for
# Wayland support.
#
# ./tokyonight.rasi is installed under xdg.configFile rather than through
# programs.rofi.theme so that both the default rofi invocation and the
# hardcoded `-theme tokyonight` flag (hyprland.nix binds, rofi-files.sh,
# the power-menu bind below) all resolve the same file — one shared
# Spotlight-style grid for every entry point.
#
# pkgs.rofi-power-menu ships the upstream `rofi-power-menu` mode script on
# PATH; hyprland.nix binds Mod+X to `rofi -show powermenu -modi
# powermenu:rofi-power-menu ...`. lockscreen is intentionally excluded via
# --choices because the script locks via `loginctl lock-session`, which
# does not launch hyprlock on this setup — the dedicated Mod+Alt+L bind in
# hyprland.nix covers locking instead.
{ pkgs, ... }:
{
  programs.rofi = {
    enable = true;
    theme = "tokyonight";
  };

  home.packages = [ pkgs.rofi-power-menu ];

  xdg.configFile = {
    "rofi/themes/tokyonight.rasi".source = ./tokyonight.rasi;

    "rofi/rofi-files.sh" = {
      source = ./rofi-files.sh;
      executable = true;
    };
  };
}
