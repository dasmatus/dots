# First-login keybind cheatsheet. Pops a rofi dmenu listing the Hyprland +
# kitty binds once, the first time the graphical session comes up on a fresh
# install, then never again (a sentinel under $XDG_STATE_HOME/dots). A
# Super+/ bind re-opens it on demand — see the bind added in hyprland.nix.
#
# The list below is curated, not introspected from hyprland.nix: those binds
# are Lua expressions (mod .. " + Q" + hl.dsp.*), so there's no clean way to
# render them to a human-readable table, and a hand list doubles as docs.
# `mod` there = SUPER. Keep this in step with the binds when editing
# hyprland.nix / kitty.nix.
{ pkgs, ... }:
let
  keybinds = [
    # launchers
    {
      key = "SUPER + Enter";
      desc = "Terminal (kitty)";
    }
    {
      key = "SUPER + D";
      desc = "App launcher (rofi)";
    }
    {
      key = "SUPER + Shift + F";
      desc = "File manager (rofi)";
    }
    {
      key = "SUPER + O";
      desc = "Obsidian";
    }
    {
      key = "SUPER + /";
      desc = "Show this keybind cheatsheet";
    }
    # window ops
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
    # focus + move
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
    # workspaces
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
    # special workspaces
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
    # overview
    {
      key = "SUPER + Tab";
      desc = "Workspace overview (Hyprspace)";
    }
    # session
    {
      key = "SUPER + Alt + L";
      desc = "Lock screen (hyprlock)";
    }
    {
      key = "SUPER + Shift + E";
      desc = "Power menu";
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
      key = "SUPER + L/R-drag";
      desc = "Move / resize window (mouse)";
    }
    # media keys
    {
      key = "Audio/Mic Mute";
      desc = "Mute sink / source";
    }
    {
      key = "Volume Up/Down";
      desc = "Volume ±5%";
    }
    {
      key = "Brightness Up/Down";
      desc = "Brightness ±5%";
    }
    # kitty (kitty.nix) — the one keybind it carries
    {
      key = "Shift + Enter";
      desc = "Send Ctrl-M (kitty, for zellij)";
    }
  ];

  # rofi dmenu shows the left column as the visible line; -no-custom keeps
  # it a read-only cheatsheet (typing just filters). The two-space gap lines
  # the key up with the description.
  entry = k: "${k.key}  ${k.desc}";
  entries = builtins.concatStringsSep "\n  " (map (k: "\"${entry k}\"") keybinds);

  # Bare invocation (from hyprland.start) shows once then writes the sentinel;
  # --force (the Super+/ bind) skips the sentinel so the sheet is recallable.
  # A short sleep on the first-login path lets waybar settle before the popup
  # grabs focus. Theme resolution mirrors rofi-files.sh (wallpaper-tui tint if
  # present, else the base tokyonight rasi).
  script = ''
    #!/usr/bin/env bash
    set -euo pipefail

    FORCE=0
    [[ "''${1:-}" == "--force" ]] && FORCE=1

    STATE="''${XDG_STATE_HOME:-$HOME/.local/state}/dots"
    SENTINEL="$STATE/keybinds-shown"
    if [[ $FORCE -eq 0 && -f "$SENTINEL" ]]; then
      exit 0
    fi
    [[ $FORCE -eq 0 ]] && sleep 2

    _TINT="''${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-tui/tint/rofi.rasi"
    if [[ -f "$_TINT" ]]; then
      THEME="$_TINT"
    else
      THEME="$HOME/.config/rofi/themes/tokyonight.rasi"
    fi

    entries=(
      ${entries}
    )

    printf '%s\n' "''${entries[@]}" \
      | rofi -dmenu -i -no-custom -theme "$THEME" -p " Keybinds" >/dev/null || true

    mkdir -p "$STATE"
    touch "$SENTINEL"
  '';
in
{
  xdg.configFile."rofi/rofi-keybinds.sh" = {
    text = script;
    executable = true;
  };
}
