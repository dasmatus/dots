# Hyprland session + per-app sandbox — the half of the home config that only
# works on a machine built for it, split out of nix/home/default.nix so
# `homeConfigurations` on a foreign host can take the other half alone.
#
# Two distinct runtime dependencies live here, neither of which is visible at
# evaluation time (these modules evaluate fine anywhere — see
# nix/home/profiles/portable.nix's header):
#
#   - desktop/: the compositor, its session units and the Quickshell tree.
#     These assume they ARE the session — Hyprland holds the seat, and
#     desktop/session/ generates the `dots-*` user units the keybinds start.
#     Installed next to a GNOME or KDE session they are dead weight at best;
#     their units start into a compositor that is not running.
#   - sandbox/: `wrap.nix` rewrites app binaries and .desktop entries to
#     launch through `dots-sandbox run`, which boots each app into a microvm.
#     The host side of that is nix/modules/system/sandbox-host.nix, a NixOS
#     module. Without it every wrapped app fails at launch — and because the
#     wrapper is the app's own entry point, that is every GUI app on the
#     profile, not a degraded subset.
{
  imports = [
    ./../desktop/hyprland.nix
    ./../desktop/session
    ./../desktop/quickshell
    ./../sandbox/machined.nix
    ./../sandbox/wrap.nix
    ./../sandbox/daemon.nix
    ./../sandbox/triage.nix
  ];
}
