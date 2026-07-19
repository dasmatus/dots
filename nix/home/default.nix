# home-manager profile aggregator — fully native modules; the raw files/
# dotfile tree is gone (git history). Every former dotfile is either a native
# module imported below (alacritty.nix, zellij.nix, fastfetch.nix, fish.nix,
# claude.nix, hyprland.nix, waybar.nix, dunst.nix, rofi/, nixvim.nix,
# librewolf.nix, dots-repo.nix) or was deliberately dropped (BetterDiscord —
# Vesktop covers it; gtk-2.0 filechooser state). GUI apps that used to be
# flatpaks live in pkgs.nix with their configs. The only generated
# raw text left is gtk-3.0/bookmarks (needs the real home directory
# interpolated).
# The X11-era stack (i3, polybar, picom, libinput-gestures, swaybg wallpaper
# exec, swayidle/swaylock, redshift) has been fully replaced by the Wayland
# modules imported below.
{ config, pkgs, ... }:
{
  imports = [
    ./alacritty.nix
    ./zellij.nix
    ./fastfetch.nix
    ./fish.nix
    ./claude.nix
    ./nixvim.nix
    ./dokumente.nix
    ./dots-repo.nix
    ./brave.nix
    ./junction.nix
    ./hyprland.nix
    ./waybar.nix
    ./dunst.nix
    ./rofi
    ./git.nix
    ./bitwarden.nix
    ./proton.nix
    ./pkgs.nix
  ];

  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  dconf.enable = true;
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      accent-color = "red";
    };
    # Traffic-light order on the left — completes the GTK theme's macos
    # tweak (gtk.theme below); Brave's caption buttons read this key too.
    "org/gnome/desktop/wm/preferences" = {
      button-layout = "close,minimize,maximize:appmenu";
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
    # Tokyonight with macOS traffic-light window buttons; the tweak is baked
    # into the generated CSS by the theme's sassc build.
    theme = {
      name = "Tokyonight-Dark";
      package = pkgs.tokyonight-gtk-theme.override {
        colorVariants = [ "dark" ];
        themeVariants = [ "default" ];
        sizeVariants = [ "standard" ];
        tweakVariants = [ "macos" ];
      };
    };
    # Since stateVersion 26.05 gtk4 no longer inherits the shared gtk.theme
    # default; without this no gtk-4.0/gtk.css @import is emitted and
    # libadwaita apps silently stay Adwaita.
    gtk4.theme = config.gtk.theme;
    iconTheme = {
      name = "MoreWaita";
      package = pkgs.morewaita-icon-theme;
    };
  };
  programs.starship.enable = true;
}
