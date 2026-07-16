# programs.alacritty port of files/alacritty/alacritty.toml (deleted — see
# git history). files/alacritty/alacritty.yml was a stale pre-0.13 duplicate
# (font size 14 vs 13) that alacritty already ignored in favour of the TOML;
# dropped without porting. The Shift+Return chars escape is written as the
# literal text \u001b\u000d — home-manager's alacritty module rewrites \uXXXX
# placeholders into real TOML escapes (ESC + CR).
# Addition vs the original: terminal.shell spawns zellij (which runs fish
# inside, per zellij.nix default_shell) instead of the login shell.
{ pkgs, lib, ... }:
{
  programs.alacritty = {
    enable = true;
    settings = {
      terminal.shell.program = lib.getExe pkgs.zellij;
      colors = {
        primary = {
          background = "0x1a1b26";
          foreground = "0xc0caf5";
        };
        normal = {
          black = "0x15161e";
          red = "0xf7768e";
          green = "0x9ece6a";
          yellow = "0xe0af68";
          blue = "0x7aa2f7";
          magenta = "0xbb9af7";
          cyan = "0x7dcfff";
          white = "0xa9b1d6";
        };
        bright = {
          black = "0x414868";
          red = "0xf7768e";
          green = "0x9ece6a";
          yellow = "0xe0af68";
          blue = "0x7aa2f7";
          magenta = "0xbb9af7";
          cyan = "0x7dcfff";
          white = "0xc0caf5";
        };
        indexed_colors = [
          {
            index = 16;
            color = "0xff9e64";
          }
          {
            index = 17;
            color = "0xdb4b4b";
          }
        ];
      };
      cursor.style = {
        shape = "Beam";
        blinking = "Always";
      };
      font = {
        size = 13;
        normal = {
          family = "Lilex Nerd Font";
          style = "Bold";
        };
      };
      keyboard.bindings = [
        {
          key = "Return";
          mods = "Shift";
          chars = "\\u001b\\u000d";
        }
      ];
    };
  };
}
