# Rofi is retired as a UI beamenu built for: the app launcher, power menu,
# file browser and (as of the beamenu-canvas migration) the settings menu
# are all beamenu (nix/home/beamenu.nix, SUPER+D / SUPER+SHIFT+E /
# SUPER+comma) or Nautilus (SUPER+SHIFT+F). `settings.rasi` (the old
# settings-menu theme) is gone along with the rofi UI it themed.
#
# `programs.rofi.enable` used to stay for one reason only: nix/home/dunst.nix
# ran `rofi -dmenu -p dunst` for its right-click context menu. dunst is gone,
# replaced by the shell's own notification server, so nothing invokes the rofi
# binary any more and the enable below is now dead weight. It is left standing
# only until the tint template below finds another home, because dropping the
# module would take the theme file with it.
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
