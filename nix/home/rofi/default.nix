# programs.rofi port of files/rofi (deleted — see git history; the theme
# and file-manager script moved here via `git mv`). nixpkgs' rofi is 2.x,
# which merged the rofi-wayland fork upstream, so no override is needed for
# Wayland support.
#
# The app launcher has moved to eww (nix/home/eww). Rofi is now used only for
# the file manager (rofi-files.sh) and the power menu. ./tokyonight.rasi is
# installed under xdg.configFile rather than through programs.rofi.theme so
# that the hardcoded `-theme tokyonight` flags (rofi-files.sh, the power-menu
# bind) resolve the same file.
#
# pkgs.rofi-power-menu ships the upstream `rofi-power-menu` mode script on
# PATH; hyprland.nix binds Mod+Shift+E to `rofi -show powermenu -modi
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
    # Settings-menu list theme — resolved by name via the
    # GLOBAL_SETTINGS_ROFI_THEME=settings wrapper env in settings-menu.nix.
    "rofi/themes/settings.rasi".source = ./settings.rasi;

    "rofi/rofi-files.sh" = {
      source = ./rofi-files.sh;
      executable = true;
    };
  };
}
