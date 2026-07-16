# home-manager mapping of files/ — dotfiles are reused wholesale via
# xdg.configFile.*.source (the Nix equivalent of the retired Gentoo /etc/skel
# copy — git history), or ported to native Home Manager modules where
# one exists (hyprland.nix, waybar.nix, dunst.nix, rofi/). Only one raw file
# is still patched:
#   - gtk-3.0/bookmarks: /home/matus → the actual home directory
# Skipped on purpose: files/neofetch (binary removed from nixpkgs; fastfetch
# replaces it), files/claude and files/BetterDiscord (personal/vendored).
# The X11-era stack (i3, polybar, picom, libinput-gestures, swaybg wallpaper
# exec, swayidle/swaylock, redshift) has been fully replaced by the Wayland
# modules imported below.
{ config, pkgs, ... }:
{
  imports = [
    ./alacritty.nix
    ./fish.nix
    ./claude.nix
    ./random_wp.nix
    ./nixvim.nix
    ./dokumente.nix
    ./librewolf.nix
    ./hyprland.nix
    ./waybar.nix
    ./dunst.nix
    ./rofi
  ];

  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  dconf.enable = true;
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      accent-color = "red";
    };
    "org/gnome/desktop/input-sources" = {
      xkb-options = [ "ctrl:esc" ];
    };
  };
  qt = {
    enable = true;
    platformTheme.name = "qtct";
    style.name = "kvantum";
  };

  xdg.configFile = {
    "zellij".source = ../../files/zellij;
    "gtk-2.0".source = ../../files/gtk-2.0;

    "gtk-3.0/bookmarks".text = ''
      file://${config.home.homeDirectory}/Dokumente/gitlab
      file://${config.home.homeDirectory}/Dokumente/github
      file://${config.home.homeDirectory}/Dokumente/schule
      file://${config.home.homeDirectory}/Dokumente/blog
    '';
  };

  home.packages = with pkgs; [
    # Wayland session tools exec'd by hyprland.nix binds; swaybg is kept for
    # the wallhaven-wallpaper service (random_wp.nix), which shells out to
    # it directly instead of going through a Home Manager module.
    swaybg
    brightnessctl
  ];
  gtk = {
    enable = true;
    theme = {
      name = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
    };
    iconTheme = {
      name = "morewaita";
      package = pkgs.morewaita-icon-theme;
    };
  };
  programs.starship.enable = true;
}
