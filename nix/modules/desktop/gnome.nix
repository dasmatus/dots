# System-level GNOME desktop. Gated on
# `config.dots.desktop.environment == "gnome"`. Everything shared with
# other DEs (pipewire, fonts, portals, PAM, flatpak, Brave policies) lives
# in common.nix; this file only carries what is unique to GNOME.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  isGnome = config.dots.desktop.environment == "gnome";
in
{
  config = lib.mkIf isGnome (
    lib.mkMerge [
      {
        services.xserver = {
          enable = true;
          displayManager.gdm.enable = true;
          desktopManager.gnome.enable = true;
        };

        # GNOME's own portal backend is pulled in by
        # services.xserver.desktopManager.gnome.enable; only the GTK
        # fallback needs adding for interfaces GNOME doesn't implement.
        xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

        # GNOME extensions system-wide (the home-manager side installs
        # user extensions; these are the ones that need system paths).
        environment.systemPackages = with pkgs; [
          gnome-tweaks
        ];
      }
    ]
  );
}
