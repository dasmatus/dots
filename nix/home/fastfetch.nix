# programs.fastfetch port of files/neofetch/config.conf (deleted — see git
# history; neofetch itself was removed from nixpkgs). Carried over: the
# print_info module order with its Nerd Font glyph keys (os keeps the literal
# "os" key of the original), the "󰇙 " separator, the NixOS ascii logo
# with distro colours, tiny distro shorthand ({name}), kernel shorthand
# ({release}), the song format, and the 0-15 colour blocks at width 3.
# Not ported: title/underline/memory/disk — neofetch had those options
# configured but print_info never displayed them. The media module needs a
# running MPRIS player over DBus (same as neofetch's song line).
{ ... }:
{
  programs.fastfetch = {
    enable = true;
    settings = {
      logo = {
        type = "builtin";
        source = "nixos";
      };
      display.separator = "  󰇙 ";
      modules = [
        {
          type = "os";
          key = "os";
          format = "{name}";
        }
        {
          type = "packages";
          key = " ";
        }
        {
          type = "kernel";
          key = " ";
          format = "{release}";
        }
        {
          type = "shell";
          key = " ";
        }
        {
          type = "terminal";
          key = " ";
        }
        {
          type = "terminalfont";
          key = " ";
        }
        {
          type = "wm";
          key = "󰖲 ";
        }
        {
          type = "theme";
          key = "󰉼 ";
        }
        {
          type = "icons";
          key = "󱌝 ";
        }
        {
          type = "media";
          key = "󰝚 ";
          format = "{artist} - {album} - {title}";
        }
        "break"
        {
          type = "colors";
          block = {
            width = 3;
            range = [
              0
              15
            ];
          };
        }
      ];
    };
  };
}
