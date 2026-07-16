# Desktop: GNOME (GDM/Wayland) + Hyprland, pipewire, fonts and themes.
# GNOME core apps are delivered as verified flatpaks (nix/modules/flatpak.nix);
# only the apps without a Flathub presence stay native below.
{ pkgs, ... }:
{
  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    gnome = {
      core-apps.enable = false;
      core-developer-tools.enable = true;
      games.enable = true;
      # nautilus previews; core-apps-gated upstream, so re-enable explicitly
      sushi.enable = true;
    };
  };
  environment.systemPackages =
    # core-apps replacements with no (verified) Flathub equivalent
    (with pkgs; [
      nautilus
      gnome-console
      gnome-system-monitor
      gnome-tecla
      yelp
    ])
    ++ (with pkgs.gnomeExtensions; [
      blur-my-shell
      dash-to-dock
      user-themes
      appindicator
      screentospace
      tiling-assistant
    ]);
  programs.gnome-disks.enable = true;
  programs.seahorse.enable = true;
  programs.hyprland.enable = true;
  # hyprlock (home-manager) can only unlock with a system PAM service
  security.pam.services.hyprlock = { };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  fonts.packages = with pkgs; [
    nerd-fonts.lilex
    nerd-fonts.agave
    noto-fonts-color-emoji
  ];
  fonts.fontconfig.defaultFonts.monospace = [ "Lilex Nerd Font" ];

  # System-wide Brave enterprise policies — matches the retired Gentoo
  # installer's files/brave/policies → /etc/brave/policies copy (git history).
  environment.etc."brave/policies".source = ../../files/brave/policies;

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "gtk";
  };

  # hyprland.conf applies themes via gsettings.
  programs.dconf.enable = true;
}
