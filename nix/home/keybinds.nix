# First-login keybind cheatsheet data. The curated list feeds the shell's
# cheatsheet overlay (nix/home/quickshell/qml/cheatsheet), reached with SUPER+/.
#
# The list is hand-curated, not introspected from hyprland.nix: those binds are
# Lua expressions (mod .. " + Q" + hl.dsp.*), so there's no clean way to render
# them to a human-readable table, and a hand list doubles as docs. `mod` there =
# SUPER. Keep this in step with the binds and gestures when editing hyprland.nix / kitty.nix.
#
# Plain data, not a home-manager module. The shell tree is also built from the
# flake as `quickshell-config` for the qmllint gate, and a module's config can
# only be read from an evaluated home-manager configuration; a file that
# evaluates to a list can be imported from either side, so the linted tree
# carries the same cheatsheet the real one does.
let
  keybinds = {
    launchers = [
      {
        key = "SUPER + Enter";
        desc = "Terminal (kitty)";
      }
      {
        key = "SUPER + Space";
        desc = "Launcher — apps, windows, system, files, clipboard";
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
      {
        key = "SUPER + comma";
        desc = "Settings (git identity, hostname, AI tools)";
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
        desc = "Privacy: mute the microphone";
      }
    ];
    kitty = [
      {
        key = "Shift + Enter";
        desc = "Send Ctrl-M (kitty, for zellij)";
      }
    ];
  };

  # Grouped, not flattened. This used to be one flat array carrying a `first`
  # boolean per row, because eww 0.6.0's `for` could iterate a top-level
  # variable but not a field of a loop variable, so `for item in group.items`
  # poisoned the whole config. A QML Repeater nests without complaint, so the
  # shape can say what it means and the marker row disappears.
in
map (category: {
  name = category;
  items = keybinds.${category};
}) (builtins.attrNames keybinds)
