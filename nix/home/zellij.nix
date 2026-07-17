# programs.zellij port of files/zellij/config.kdl (deleted — see git history),
# rendered through home-manager's toKDL generator (_args/_props/_children).
# Deliberate changes vs the original:
#   - copy_command: xclip → wl-copy (Wayland session; store path via getExe',
#     wl-clipboard was never installed)
#   - simplified_ui false dropped (zellij default)
#   - bind "Escape" → "Esc": zellij rejects "Escape" as a key name; the
#     original config was never validated (the binary was never installed)
# Kept verbatim: the duplicate tmux-mode "l" bind (Scroll, then MoveFocus
# "Right"); zellij resolves duplicates last-wins, so behaviour is unchanged.
# Note: zellij itself was never installed before — this module adds the binary.
{ pkgs, lib, ... }:
let
  # bind "t" [ actions… ] → one KDL `bind "t" { …; }` node
  bind = key: actions: {
    bind = {
      _args = [ key ];
      _children = actions;
    };
  };
  toNormal = {
    SwitchToMode = "Normal";
  };
in
{
  programs.zellij = {
    enable = true;
    settings = {
      show_startup_tips = false;
      keybinds = {
        _props."clear-defaults" = false;
        tmux._children = [
          (bind "Esc" [ toNormal ])
          (bind "t" [
            { NewTab = { }; }
            toNormal
          ])
          (bind "c" [
            { CloseFocus = { }; }
            toNormal
          ])
          (bind "n" [
            { GoToNextTab = { }; }
            toNormal
          ])
          (bind "p" [
            { GoToPreviousTab = { }; }
            toNormal
          ])
          (bind "," [ { SwitchToMode = "RenameTab"; } ])
          (bind "s" [
            { NewPane = "Down"; }
            toNormal
          ])
          (bind "v" [
            { NewPane = "Right"; }
            toNormal
          ])
          (bind "f" [
            { NewPane = { }; }
            toNormal
          ])
          (bind "l" [ { SwitchToMode = "Scroll"; } ])
          (bind "z" [
            { ToggleFocusFullscreen = { }; }
            toNormal
          ])
          (bind "Space" [ { NextSwapLayout = { }; } ])
          (bind "h" [
            { MoveFocus = "Left"; }
            toNormal
          ])
          (bind "j" [
            { MoveFocus = "Down"; }
            toNormal
          ])
          (bind "k" [
            { MoveFocus = "Up"; }
            toNormal
          ])
          (bind "l" [
            { MoveFocus = "Right"; }
            toNormal
          ])
          (bind "Left" [
            { MoveFocus = "Left"; }
            toNormal
          ])
          (bind "Right" [
            { MoveFocus = "Right"; }
            toNormal
          ])
          (bind "Down" [
            { MoveFocus = "Down"; }
            toNormal
          ])
          (bind "Up" [
            { MoveFocus = "Up"; }
            toNormal
          ])
          (bind "d" [ { Detach = { }; } ])
          (bind "[" [ { SwitchToMode = "Scroll"; } ])
        ];
        shared_except = {
          _args = [
            "normal"
            "locked"
          ];
          _children = [ (bind "Esc" [ toNormal ]) ];
        };
      };

      themes.tokyonight = {
        fg = "#c0caf5";
        bg = "#1a1b26";
        black = "#15161e";
        red = "#f7768e";
        green = "#9ece6a";
        yellow = "#e0af68";
        blue = "#7aa2f7";
        magenta = "#bb9af7";
        cyan = "#7dcfff";
        white = "#a9b1d6";
        orange = "#ff9e64";
      };
      theme = "tokyonight";

      # Every new terminal window attaches to the one "main" session instead
      # of spawning a fresh session per window.
      session_name = "main";
      attach_to_session = true;

      default_layout = "default";
      default_shell = "fish";
      pane_frames = true;
      ui.pane_frames = {
        rounded_corners = true;
        hide_session_name = false;
      };
      session_serialization = true;
      serialize_pane_viewport = true;
      mouse_mode = true;
      scroll_buffer_size = 10000;
      copy_on_select = true;
      copy_command = lib.getExe' pkgs.wl-clipboard "wl-copy";
    };
  };
}
