# Desktop: i3 (X11, started via startx from fish on tty1) + Hyprland (Wayland,
# launched manually), pipewire, fonts and themes referenced by files/ configs.
# redshift/picom/polybar are exec'd by the i3/hypr configs themselves, so they
# are provided as packages, not as NixOS services (avoids double instances).
{ pkgs, ... }:
{
  services.xserver = {
    enable = true;
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        i3status
        autotiling
        dex
      ];
    };
    displayManager.startx.enable = true;
  };

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

  # i3/hypr configs run KeePassXC and Flameshot via `flatpak run`.
  services.flatpak.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "gtk";
  };

  # hyprland.conf applies themes via gsettings.
  programs.dconf.enable = true;
}
