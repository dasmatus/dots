# programs.rofi port of files/rofi (deleted — see git history; the theme
# and file-manager script moved here via `git mv`). nixpkgs' rofi is 2.x,
# which merged the rofi-wayland fork upstream, so no override is needed for
# Wayland support.
#
# ./tokyonight.rasi is installed under xdg.configFile rather than through
# programs.rofi.theme so that both the default rofi invocation and the
# hardcoded `-theme tokyonight` flag (hyprland.nix binds, rofi-files.sh)
# resolve the same file.
{ ... }:
{
  programs.rofi = {
    enable = true;
    theme = "tokyonight";
  };

  xdg.configFile = {
    "rofi/themes/tokyonight.rasi".source = ./tokyonight.rasi;

    "rofi/rofi-files.sh" = {
      source = ./rofi-files.sh;
      executable = true;
    };
  };
}
