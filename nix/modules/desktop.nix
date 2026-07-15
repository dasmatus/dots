# Desktop: i3 (X11, started via startx from fish on tty1) + Hyprland (Wayland,
# launched manually), pipewire, fonts and themes referenced by files/ configs.
# redshift/picom/polybar are exec'd by the i3/hypr configs themselves, so they
# are provided as packages, not as NixOS services (avoids double instances).
{ pkgs, ... }:
{
  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    gnome = {
      core-apps.enable = true;
      developer-tools.enable = true;
      games.enable = true;
    };
  };
  environment.systemPackages = with pkgs.gnomeExtensions; [
    blur-my-shell
    dash-to-dock
    user-themes
    appindicator
    screentospace
    tiling-assistant
  ];
  programs.hyprland.enable = true;

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

  environment.systemPackages = with pkgs; [
    alacritty
    brave
    rofi
    picom
    polybarFull
    dunst
    redshift
    brightnessctl
    betterlockscreen
    xss-lock
    libinput-gestures
    nitrogen
    networkmanagerapplet
    tokyonight-gtk-theme
    papirus-icon-theme
    adwaita-icon-theme
  ];

  # System-wide Brave enterprise policies — parity with the Gentoo installer's
  # files/brave/policies → /etc/brave/policies copy.
  environment.etc."brave/policies".source = ../../files/brave/policies;

  # i3/hypr configs run KeePassXC and Flameshot via `flatpak run`. NixOS's
  # flatpak module configures no remotes, so add flathub once — without it
  # every `flatpak install/run` fails on a fresh system.
  services.flatpak.enable = true;
  systemd.services.flathub-remote = {
    description = "Add the flathub flatpak remote";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.flatpak ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      flatpak remote-add --if-not-exists --verified flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    '';
  };
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "gtk";
  };

  # hyprland.conf applies themes via gsettings.
  programs.dconf.enable = true;
}
