# Home-manager GNOME desktop config. Imported by
# nix/home/profiles/session.nix when dots.desktop.environment == "gnome".
# Shares GTK/Qt/dconf/cursor with the other DEs through ./common.nix.
#
# GNOME is the most different of the three DEs: no compositor IPC for
# keybindings (Mutter doesn't expose one), no Lua DSL, no `swaymsg`.
# Keybindings go through dconf custom keybindings; the session actions
# table is consumed for its `commands` (app launches, OSD toggles) but
# most `dispatch` actions (focus, workspace, window management) have no
# GNOME equivalent and are silently dropped — GNOME's own keybinding
# system handles those through its settings UI.
{
  config,
  pkgs,
  lib,
  settings,
  ...
}:
let
  cfg = config.dots.session;
  actions = import ./session/actions.nix;
  keyedActions = builtins.filter (a: a.key != null) actions;

  # GNOME custom keybindings go through dconf. Only non-dispatch actions
  # (app launches, OSD toggles) can be bound this way; dispatch actions
  # (focus, workspace switching, window management) are Mutter's own and
  # configured through GNOME Settings, not custom keybindings.
  nonDispatchKeyed = builtins.filter (a: a.kind != "dispatch" && a.key != null) actions;

  # Render a keybinding for dconf: mods joined with +, key appended.
  # GNOME uses <Super>, <Shift>, <Alt>, <Ctrl> angle-bracket syntax.
  mkGnomeKey =
    a:
    let
      modMap = {
        SUPER = "Super";
        SHIFT = "Shift";
        ALT = "Alt";
        CTRL = "Ctrl";
      };
      mods = map (m: "<${modMap.${m} or m}>") a.mods;
    in
    "${lib.concatStrings mods}${a.key}";

  # Build the dconf custom-keybindings list.
  gnomeKeybinds = lib.listToAttrs (
    lib.imap0 (i: a: {
      name = "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${toString i}";
      value = {
        name = a.desc;
        command = cfg.commands.${a.name} or "";
        binding = mkGnomeKey a;
      };
    }) nonDispatchKeyed
  );

  # The list of custom keybinding paths (dconf needs this index).
  customKeybindingPaths = map (i: "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${toString i}/") (
    lib.range 0 (builtins.length nonDispatchKeyed - 1)
  );
in
{
  imports = [ ./common.nix ];

  # GNOME-specific dconf settings.
  dconf.settings = {
    # Custom keybindings for app launches and OSD toggles.
    "org/gnome/settings-daemon/plugins/media-keys" = {
      custom-keybindings = customKeybindingPaths;
    };
  }
  // gnomeKeybinds;

  # GNOME has no compositor-level screenshot tool binding; use the
  # built-in screenshot UI (Print key) which GNOME handles natively.
  # The session actions for screenshots are not bound here.

  # GNOME session variables.
  systemd.user.sessionVariables = {
    XDG_CURRENT_DESKTOP = "GNOME";
    XDG_SESSION_DESKTOP = "gnome";
  };

  # GNOME-specific packages.
  home.packages = with pkgs; [
    libnotify
    xdg-user-dirs
  ];

  # redshift -l 48.15:17.11 -t 4500:3000 -b 0.9:0.75 → gammastep.
  services.gammastep = {
    enable = true;
    latitude = "48.15";
    longitude = "17.11";
    temperature = {
      day = 4500;
      night = 3000;
    };
    tray = true;
    settings.general = {
      brightness-day = 0.9;
      brightness-night = 0.75;
    };
  };
}
