# The Hyprland session — the half of the home config that only works on a
# machine built for it, split out of nix/home/default.nix so
# `homeConfigurations` on a foreign host can take the other half alone.
#
# desktop/: the compositor, its session units and the Quickshell tree. These
# assume they ARE the session — Hyprland holds the seat, and desktop/session/
# generates the `dots-*` user units the keybinds start. Installed next to a
# GNOME or KDE session they are dead weight at best; their units start into a
# compositor that is not running. (The per-app sandbox that used to live
# beside this profile as `sandbox/` was retired for Flatpak + AppArmor —
# see git history; nix/home/ai/triage-assist.nix is the one piece of it that
# outlived the deletion, and it lives with the other AI-harness modules now.)
{
  imports = [
    ./../desktop/hyprland.nix
    ./../desktop/session
    ./../desktop/quickshell
  ];
}
