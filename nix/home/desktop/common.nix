# Home-manager desktop configuration shared by all three DEs. This module
# is intentionally minimal: GTK theme, Qt platform theme, dconf defaults,
# and cursor config live in nix/home/profiles/portable.nix (which every
# profile imports), so they are NOT repeated here. This file only carries
# what is desktop-session-specific but NOT compositor-specific — currently
# nothing, but it exists as the import point for future shared session
# config that doesn't belong in portable.nix.
#
# Each per-DE home module (hyprland.nix, sway.nix, gnome.nix) imports this
# and adds its own compositor config.
{ ... }:
{
  # Intentionally empty. See header for why.
}
