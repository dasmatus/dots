# Rewrite of files/fish/config.fish — the one dotfile that is not reused
# wholesale. Changes vs the original:
#   - the tty1 `exec startx` block is gone: GDM (nix/modules/desktop.nix)
#     owns session startup now, and startx is X11-only
#   - fastfetch replaces neofetch (removed from nixpkgs)
#   - starship init comes from programs.starship
#   - linuxbrew/bun/dotnet/Antigravity PATH cruft dropped (host-specific,
#     none of it exists on NixOS)
{ ... }:
{
  programs.fish = {
    enable = true;

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
