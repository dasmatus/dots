# System-level Sway compositor. Gated on
# `config.dots.desktop.environment == "sway"`. Everything shared with
# other DEs (pipewire, fonts, portals, PAM, flatpak, Brave policies) lives
# in common.nix; this file only carries what is unique to Sway.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  isSway = config.dots.desktop.environment == "sway";
in
{
  config = lib.mkIf isSway (
    lib.mkMerge [
      {
        # greetd + tuigreet as the display manager. Sway has no regreet
        # equivalent (regreet is Hyprland-specific); tuigreet is the
        # minimal, well-maintained greetd frontend.
        services.greetd = {
          enable = true;
          settings = {
            default_session = {
              command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd sway";
              user = "greeter";
            };
          };
        };

        programs.sway = {
          enable = true;
          # Use nixpkgs' Sway (the module's default `package`). Same
          # rationale as Hyprland: nixpkgs' build is on cache.nixos.org,
          # a pinned input's prebuilt is not.
          wrapperFeatures.gtk = true;
        };

        # xdg-desktop-portal-wlr for Sway (ScreenCast/Screenshot).
        # programs.sway.enable sets xdg.portal.enable = true and adds
        # xdg-desktop-portal-wlr to extraPortals; only the GTK backend
        # needs adding here for FileChooser/Settings.
        xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      }
    ]
  );
}
