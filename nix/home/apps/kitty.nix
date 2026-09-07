# programs.kitty — port of alacritty.nix (deleted — see git history), kept
# equally minimal: only the shell, colours, cursor, font and one keybind the
# original carried. kitty is GPU-accelerated like Alacritty but its kitten
# runtime ships with the nixpkgs package regardless; no extras are enabled
# here. Settings ported 1:1, with kitty's config syntax differences:
#   - colours: 0xRRGGBB → #RRGGBB (kitty.conf colour format)
#   - font: Alacritty's normal.style = "Bold" (regular text rendered in the
#     Bold face) has no kitty equivalent — font_family takes a font/PostScript
#     name, so LilexNF-Bold (the Bold face's PostScript name, confirmed via
#     fc-query) is set as the regular font; bold_font pinned to the same so
#     kitty doesn't synthesise a "bolder" variant for bold runs.
#   - cursor: Alacritty blinking = Always → cursor_stop_blinking_after 0
#     (zero = never stop blinking).
# Kept verbatim: terminal shell spawns zellij (which runs fish inside, per
# zellij.nix default_shell) instead of the login shell.
{ pkgs, lib, ... }:
{
  programs.kitty = {
    enable = true;
    settings = {
      shell = lib.getExe pkgs.zellij;
      foreground = "#c0caf5";
      background = "#1a1b26";
      color0 = "#15161e";
      color1 = "#f7768e";
      color2 = "#9ece6a";
      color3 = "#e0af68";
      color4 = "#7aa2f7";
      color5 = "#bb9af7";
      color6 = "#7dcfff";
      color7 = "#a9b1d6";
      color8 = "#414868";
      color9 = "#f7768e";
      color10 = "#9ece6a";
      color11 = "#e0af68";
      color12 = "#7aa2f7";
      color13 = "#bb9af7";
      color14 = "#7dcfff";
      color15 = "#c0caf5";
      color16 = "#ff9e64";
      color17 = "#db4b4b";
      cursor_shape = "beam";
      cursor_blink_interval = "0.5";
      cursor_stop_blinking_after = "0";
      # "Lilex Nerd Font Mono", not "LilexNF". The old value named a family
      # nothing on this machine provides: nixpkgs' nerd-fonts.lilex
      # (nix/home/base/pkgs.nix) registers "Lilex Nerd Font", "... Mono" and
      # "... Propo"; the compact "LilexNF" spelling exists only in a
      # differently-patched build. fontconfig does not fail on an unknown
      # family, it SUBSTITUTES -- `fc-match LilexNF` answered
      # NotoSans-Regular -- so kitty silently rendered in a proportional font
      # carrying no Nerd Font glyphs, which is where the tofu came from. Two
      # separate faults produced one symptom: no font package was installed at
      # all, and this name would not have matched it even so.
      #
      # The Mono cut specifically: it is the fixed-advance one (fontconfig
      # spacing 100) and a terminal needs one cell width. The bare
      # "Lilex Nerd Font" and "... Propo" cuts use each glyph's natural
      # advance, which suits a proportional UI and not a grid.
      font_family = "Lilex Nerd Font Mono";
      bold_font = "Lilex Nerd Font Mono";
      font_size = "12";
    };
    # Shift+Return sends ESC + CR, matching the Alacritty binding
    # (chars \u001b\u000d). kitty's send_text takes \x1b (ESC) and \x0d (CR).
    keybindings = {
      "shift+enter" = "send_text all \\x1b\\x0d";
    };
  };
}
