# First-login keybind cheatsheet data. The curated list is emitted as
# ~/.config/eww/keybinds.json and rendered by the eww keybinds window
# (nix/home/eww/eww.yuck). The window pops once, the first time the graphical
# session comes up on a fresh install, then never again (a sentinel under
# $XDG_STATE_HOME/dots). A SUPER+/ bind re-opens it on demand — see the bind
# added in hyprland.nix.
#
# The list is hand-curated, not introspected from hyprland.nix: those binds are
# Lua expressions (mod .. " + Q" + hl.dsp.*), so there's no clean way to render
# them to a human-readable table, and a hand list doubles as docs. `mod` there =
# SUPER. Keep this in step with the binds and gestures when editing hyprland.nix / kitty.nix.
{ ... }:
let
  keybinds = {
    launchers = [
      {
        key = "SUPER + Enter";
        desc = "Terminal (kitty)";
      }
      {
        key = "SUPER + Space";
        desc = "Launcher (beamenu) — apps, settings, system, plugins";
      }
      {
        key = "SUPER + Shift + F";
        desc = "File manager (Nautilus)";
      }
      {
        key = "SUPER + O";
        desc = "Obsidian";
      }
      {
        key = "SUPER + Z";
        desc = "Zed editor";
      }
      {
        key = "SUPER + /";
        desc = "Show this keybind cheatsheet";
      }
    ];
    window = [
      {
        key = "SUPER + Q";
        desc = "Close window";
      }
      {
        key = "SUPER + Shift + Space";
        desc = "Toggle floating";
      }
      {
        key = "SUPER + F";
        desc = "Fullscreen";
      }
      {
        key = "SUPER + P";
        desc = "Pseudo-tiling";
      }
      {
        key = "SUPER + Alt + H/J/K/L";
        desc = "Resize window";
      }
    ];
    focus = [
      {
        key = "SUPER + H/J/K/L";
        desc = "Focus left/down/up/right";
      }
      {
        key = "SUPER + Arrows";
        desc = "Focus (arrows)";
      }
      {
        key = "SUPER + Shift + H/J/K/L";
        desc = "Move window";
      }
      {
        key = "SUPER + Shift + Arrows";
        desc = "Move window (arrows)";
      }
    ];
    workspaces = [
      {
        key = "SUPER + 1..0";
        desc = "Workspace 1–10";
      }
      {
        key = "SUPER + Shift + 1..0";
        desc = "Move window to workspace 1–10";
      }
      {
        key = "SUPER + mouse wheel";
        desc = "Cycle workspaces";
      }
    ];
    special = [
      {
        key = "SUPER + minus";
        desc = "Toggle scratch workspace";
      }
      {
        key = "SUPER + Shift + minus";
        desc = "Move window to scratch";
      }
      {
        key = "SUPER + S";
        desc = "Toggle magic workspace";
      }
      {
        key = "SUPER + Shift + S";
        desc = "Move window to magic workspace";
      }
    ];
    session = [
      {
        key = "SUPER + Alt + L";
        desc = "Lock screen (hyprlock)";
      }
      {
        key = "SUPER + Shift + C";
        desc = "Reload Hyprland config";
      }
      {
        key = "Print";
        desc = "Screenshot (whole screen)";
      }
      {
        key = "SUPER + Print";
        desc = "Screenshot (select region)";
      }
      {
        key = "SUPER + L/R-drag";
        desc = "Move / resize window (mouse)";
      }
    ];
    touchpad = [
      {
        key = "3-finger swipe left / right";
        desc = "Switch workspaces";
      }
      {
        key = "4-finger swipe left / right";
        desc = "Move window to adjacent workspace";
      }
      {
        key = "4-finger swipe down";
        desc = "Toggle scratch workspace";
      }
    ];
    media = [
      {
        key = "Audio/Mic Mute";
        desc = "Mute sink / source (shows an OSD)";
      }
      {
        key = "Volume Up/Down";
        desc = "Volume ±5% (shows an OSD)";
      }
      {
        key = "Brightness Up/Down";
        desc = "Brightness ±5% (shows an OSD)";
      }
      {
        key = "SUPER + Shift + T";
        desc = "Touchpad on / off";
      }
      {
        key = "SUPER + Shift + P";
        desc = "Privacy: mute mic, report camera use";
      }
    ];
    kitty = [
      {
        key = "Shift + Enter";
        desc = "Send Ctrl-M (kitty, for zellij)";
      }
    ];
  };

  # Flat array, not nested {category, items}: eww 0.6.0's `for` can iterate a
  # top-level variable but cannot iterate a field of a loop variable
  # (`for item in group.items` → "No variable named `group.items` in scope"),
  # which poisons the whole config and takes down the launcher window too.
  # `first` marks the first row of each category so the yuck can show the
  # category header only once per group via `:visible {item.first}`.
  json = builtins.toJSON (
    builtins.concatLists (
      map (
        category:
        let
          items = keybinds.${category};
        in
        builtins.genList (
          i:
          let
            item = builtins.elemAt items i;
          in
          {
            inherit category;
            first = i == 0;
            inherit (item) key desc;
          }
        ) (builtins.length items)
      ) (builtins.attrNames keybinds)
    )
  );
in
{
  xdg.configFile."eww/keybinds.json".text = json;
}
