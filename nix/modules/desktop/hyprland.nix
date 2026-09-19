# System-level Hyprland compositor. Gated on
# `config.dots.desktop.environment == "hyprland"`. Everything shared with
# other DEs (pipewire, fonts, portals, PAM, flatpak, Brave policies) lives
# in common.nix; this file only carries what is unique to Hyprland.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  isHyprland = config.dots.desktop.environment == "hyprland";
in
{
  config = lib.mkIf isHyprland (lib.mkMerge [
    {
      services.displayManager.regreet = {
        enable = true;
        font = {
          name = "Lilex Nerd Font";
          size = 14;
        };
        theme = {
          name = "adw-gtk3-dark";
          package = pkgs.adw-gtk3;
        };
        iconTheme = {
          name = "Papirus";
          package = pkgs.papirus-icon-theme;
        };
        settings = {
          background = {
            path = "/home/matus/Dokumente/codeberg/personal/dots/Wallpapers/wh/wallhaven-w5dgxr.jpg";
          };
        };
      };

      programs.hyprland = {
        enable = true;
        # Use nixpkgs' Hyprland (the module's default `package`) rather
        # than a pinned Hyprland flake input. The flake-input route needs
        # hyprland.cachix.org, whose CI rebuilds main with bumped inputs
        # on every push — so a pinned release tag's prebuilt ages out of
        # the cache and nixos-rebuild silently falls back to a from-source
        # C++ build (verified: v0.55.0's prebuilt was evicted ~3 months
        # after release). nixpkgs' Hyprland is built by Hydra and lives on
        # cache.nixos.org, which retains builds indefinitely, so the
        # compositor is always substituted. Trade-off: the Hyprland
        # version now advances with `nix flake update` of nixpkgs instead
        # of being pinned independently.
        withUWSM = true;
        # Gated on dots.xwayland.enable (nix/modules/dots.nix), default
        # true. Phase C
        # (docs/superpowers/specs/2026-09-08-hardening-design.md) tried
        # removing XWayland outright on the premise that every GUI app
        # here is a Wayland-native Flatpak — but Haveno
        # (nix/home/base/pkgs.nix, a JavaFX/jpackage bundle; OpenJFX has
        # no Wayland backend) and Steam (nix/modules/desktop/steam.nix,
        # an X11-only client) both need it, so a hard `false` broke
        # them. A toggle keeps the removal one boolean away for when
        # both apps go, instead of silently reintroducing XWayland
        # unconditionally or hiding the dependency again. Upstream's own
        # default is `true`, so this has to be a real assignment, not a
        # deleted line — `xwayland.enable` feeds `enableXWayland` on the
        # Hyprland package build itself (nixpkgs'
        # nixos/modules/programs/wayland/hyprland.nix), so a merely-absent
        # option here would silently keep XWayland built in and running
        # regardless of the toggle.
        xwayland.enable = config.dots.xwayland.enable;
      };

      # programs.hyprland.enable above already sets xdg.portal.enable =
      # true and adds xdg-desktop-portal-hyprland (as cfg.portalPackage,
      # overridden with the flake Hyprland) to extraPortals. Listing it
      # again here would put a second, distinct store path shipping
      # xdg-desktop-portal-hyprland.service into systemd.packages, and
      # generateUnits (nixos/lib/systemd-lib.nix) symlinks each unit with
      # plain `ln -s` (no -f) — two derivations, same unit filename →
      # "failed to create symlink ...: file exists". So only the GTK
      # backend is added here; both backends end up in the system portal
      # dir so hyprland-portals.conf can dispatch Screenshot/ScreenCast to
      # hyprland and Settings/FileChooser to gtk.
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];

      # PAM U2F for hyprlock and the ly display manager.
      security.pam.services = {
        hyprlock.u2fAuth = true;
        ly.u2fAuth = true;
      };
    }

    # 2FA tightening: hyprlock and ly get the same required+deny-removal
    # treatment as login (common.nix).
    (lib.mkIf config.dots.fido.requireKey {
      security.pam.services.hyprlock.rules.auth.unix.control = lib.mkForce "required";
      security.pam.services.ly.rules.auth.unix.control = lib.mkForce "required";
      security.pam.services.hyprlock.rules.auth.deny.enable = false;
      security.pam.services.ly.rules.auth.deny.enable = false;
    })
  ]);
}
