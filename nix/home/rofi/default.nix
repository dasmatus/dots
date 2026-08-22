# Rofi is no longer a user-facing launcher — the app launcher, power menu
# and file browser are beamenu (nix/home/beamenu.nix, SUPER+D / SUPER+SHIFT+E)
# or Nautilus (SUPER+SHIFT+F).
# What remains here is rofi as a RENDERING DEPENDENCY of the settings menu:
# rust/settings-global shells out to `rofi -dmenu` (nix/home/settings-menu.nix
# points it at settings.rasi via GLOBAL_SETTINGS_ROFI_THEME), so the binary
# must stay on PATH. nixpkgs' rofi is 2.x, which merged the rofi-wayland fork
# upstream, so no override is needed for Wayland support.
#
# tokyonight.rasi is kept only as the TEMPLATE wallpaper-tui's tint engine
# reads (rust/wallpaper-tui/src/tint.rs substitutes accent vars into it to
# write ~/.local/state/wallpaper-tui/tint/rofi.rasi).
{ pkgs, ... }:
{
  programs.rofi.enable = true;

  xdg.configFile = {
    "rofi/themes/tokyonight.rasi".source = ./tokyonight.rasi;
    # Settings-menu list theme — resolved by name via the
    # GLOBAL_SETTINGS_ROFI_THEME=settings wrapper env in settings-menu.nix.
    "rofi/themes/settings.rasi".source = ./settings.rasi;
  };
}
