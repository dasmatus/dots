# Rofi is retired as a UI beamenu built for: the app launcher, power menu,
# file browser and (as of the beamenu-canvas migration) the settings menu
# are all beamenu (nix/home/beamenu.nix, SUPER+D / SUPER+SHIFT+E /
# SUPER+comma) or Nautilus (SUPER+SHIFT+F). `settings.rasi` (the old
# settings-menu theme) is gone along with the rofi UI it themed.
#
# `programs.rofi.enable` stays regardless: grepping before dropping it turned
# up nix/home/dunst.nix:65 (`dmenu = "rofi -dmenu -p dunst"`, dunst's
# right-click context menu), an independent runtime consumer of the `rofi`
# binary that has nothing to do with settings-global. Dropping this would
# silently break that dunst action.
#
# tokyonight.rasi is kept installed for a second, unrelated reason:
# wallpaper-tui's tint engine reads it at runtime as a source template —
# TintCtx::rofi_base points at $XDG_CONFIG_HOME/rofi/themes/tokyonight.rasi
# (rust/wallpaper-tui/src/tint.rs) and substitutes the live accent/
# selected-bg into it to write ~/.local/state/wallpaper-tui/tint/rofi.rasi.
{ ... }:
{
  programs.rofi.enable = true;

  xdg.configFile."rofi/themes/tokyonight.rasi".source = ./tokyonight.rasi;
}
