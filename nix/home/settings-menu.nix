# Settings menu (rust/settings-global, built at the flake level as
# packages.${system}.settings and handed in via extraSpecialArgs like
# wallpaperTui/hyprmon): edits the installer answers in
# /var/lib/dots/settings.nix. `global-settings serve` speaks JSON-RPC over
# stdio to beamenu-canvas (rust/beamenu-canvas), which renders the form —
# reached via the "settings" beamenu plugin manifest below, and from the
# SUPER+comma bind in hyprland.nix; cheatsheet entry in keybinds.nix.
# `dump`/`set` are the scripting-facing headless modes. This module no
# longer touches rofi at all — see nix/home/rofi/default.nix for what still
# keeps the `rofi` binary around (dunst's context menu, unrelated to this).
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
  ...
}:
{
  home.packages = [ settingsMenu ];

  # programs.beamenu.plugins is added by a parallel task (not yet present in
  # this worktree at time of writing — see task-F-brief.md); this config is
  # written against its binding schema regardless, per the brief.
  programs.beamenu.plugins.settings = {
    name = "settings";
    title = "Settings";
    keyword = "set";
    commands = [
      {
        id = "edit";
        title = "System Settings";
        description = "Edit installer answers";
        mode = "view";
        ui = "rpc";
        exec = [
          "global-settings"
          "serve"
        ];
      }
    ];
  };

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
