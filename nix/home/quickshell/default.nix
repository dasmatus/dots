# Quickshell is the desktop shell. Bar, notifications, OSD, launcher and the
# settings form all live in one QML tree (nix/home/quickshell/qml) instead of
# the waybar + dunst + eww + rofi + beamenu pile they replace, so there is one
# palette, one IPC socket and one process to reason about.
#
# pkgs.quickshell rather than a flake input, for the reason flake.nix:48-58
# gives about Hyprland: nixpkgs' build is on cache.nixos.org, a pinned input's
# prebuilt is not, and the difference is a compositor-sized source build on
# every rebuild.
{
  pkgs,
  config,
  ...
}:
let
  tree = import ./tree.nix {
    inherit pkgs;
    stateHome = config.xdg.stateHome;
  };
in
{
  home.packages = [ pkgs.quickshell ];

  # Lands at $XDG_CONFIG_HOME/quickshell, which is where a bare `qs` looks for
  # shell.qml, so the compositor's exec line needs no --path.
  xdg.configFile."quickshell".source = tree;
}
