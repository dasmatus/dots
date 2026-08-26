# Claude Desktop for Linux (beta). Chat, Cowork and Claude Code in one app.
#
# The derivation is nix/claude-desktop.nix, built at the flake level and handed
# in via extraSpecialArgs like wallpaperTui. It repackages upstream's
# .deb because that is the only channel they publish: the documented install is
# an apt repository (https://code.claude.com/docs/en/desktop-linux), which has
# no NixOS analogue, so the package is pinned by digest and bumped by hand.
#
# The app does not self-update on Linux even when installed the documented way,
# so nothing is lost by pinning; see the bump recipe in nix/claude-desktop.nix.
{
  claudeDesktop,
  config,
  lib,
  ...
}:
let
  cfg = config.programs.claude-desktop;
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "the Claude desktop app" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ claudeDesktop ];

    # The app stores its session in the Secret Service, which on this machine
    # is gnome-keyring (pulled in by the GNOME session; also what Proton Mail
    # Bridge uses, see proton.nix). Without one running, sign-in does not
    # persist across restarts.
    #
    # Sign-in itself is interactive and cannot be declared: launch it once and
    # log in with the claude.ai account.
  };
}
