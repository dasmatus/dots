# Settings menu (rust/settings-global, built at the flake level as
# packages.${system}.settings and handed in via extraSpecialArgs like
# wallpaperTui/hyprmon): edits the installer answers in
# /var/lib/dots/settings.nix. Launched by name (`global-settings`) from the
# SUPER+comma bind in hyprland.nix, and reachable from beamenu; cheatsheet
# entry in keybinds.nix. Renders via rofi -dmenu, the last rofi consumer
# (see nix/home/rofi/default.nix).
#
# The menu runs as the user; only the root-owned file write re-execs the
# binary under pkexec. pkexec needs a polkit *authentication agent* in the
# session to show the password dialog — the system polkitd alone cannot
# prompt, and nothing else in this config ships an agent — so
# hyprpolkitagent rides along as a user service. The package ships this
# exact unit, but HM only links units it declares itself, so it is restated
# here with the store-path ExecStart.
{
  settingsMenu,
  pkgs,
  lib,
  ...
}:
let
  # Thin wrapper (same pattern as wallpaper-tui.nix): point the binary at
  # the dedicated rasi (nix/home/rofi/settings.rasi, installed to
  # ~/.config/rofi/themes by rofi/default.nix — rofi resolves the bare name
  # against that dir). Overridable via env for dev/tests.
  settings-menu = pkgs.writeShellScriptBin "global-settings" ''
    export GLOBAL_SETTINGS_ROFI_THEME="''${GLOBAL_SETTINGS_ROFI_THEME:-settings}"
    exec ${lib.getExe settingsMenu} "$@"
  '';
in
{
  home.packages = [ settings-menu ];

  systemd.user.services.hyprpolkitagent = {
    Unit = {
      Description = "Hyprland Polkit Authentication Agent";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      # No bin/ in the package — upstream installs to libexec only, so
      # lib.getExe (bin/hyprpolkitagent) would point at a missing path.
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Slice = "session.slice";
      TimeoutStopSec = "5sec";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
