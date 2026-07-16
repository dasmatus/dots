# Rewrite of files/fish/config.fish — the one dotfile that is not reused
# wholesale. Changes vs the original:
#   - startx only fires on tty1 with no display (the original ran on ANY
#     login shell, including ssh) and uses exec so logout ends the session
#   - fastfetch replaces neofetch (removed from nixpkgs)
#   - starship init comes from programs.starship
#   - linuxbrew/bun/dotnet/Antigravity PATH cruft dropped (host-specific,
#     none of it exists on NixOS)
{ ... }:
{
  programs.fish = {
    enable = true;

    loginShellInit = ''
      if test (tty) = /dev/tty1; and not set -q DISPLAY
          exec startx
      end
    '';

    interactiveShellInit = ''
      set -g fish_greeting
      fastfetch
    '';

    shellAliases = {
      cat = "bat --paging=never";
      ls = "eza -lhi --git --icons";
      claude = "claude --worktree";
    };
  };
}
