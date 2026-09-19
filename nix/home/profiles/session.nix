# The desktop session — the half of the home config that only works on a
# machine built for it, split out of nix/home/default.nix so
# `homeConfigurations` on a foreign host can take the other half alone.
#
# This profile is a dispatcher: it imports the shared session infrastructure
# (actions, keybinds, quickshell) unconditionally, then the per-DE home
# module selected by `dots.desktop.environment`. Each per-DE module carries
# its compositor config, its lock screen, and its own keybind rendering.
#
# desktop/session/: the compositor-agnostic action table and the systemd
# unit generator. These assume they ARE the session — the compositor holds
# the seat, and session/ generates the `dots-*` user units the keybinds
# start. Installed next to a foreign DE they are dead weight at best;
# their units start into a compositor that is not running.
{
  dots,
  ...
}:
{
  imports = [
    ./../desktop/session
    ./../desktop/quickshell
  ]
  ++ (
    if dots.desktop.environment == "gnome" then
      [ ./../desktop/gnome.nix ]
    else if dots.desktop.environment == "sway" then
      [ ./../desktop/sway.nix ]
    else
      [ ./../desktop/hyprland.nix ]
  );
}
