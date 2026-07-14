# home-manager mapping of files/ — dotfiles are reused wholesale via
# xdg.configFile.*.source (the Nix equivalent of the Gentoo /etc/skel copy in
# installer/chroot_system.py). Only two files are patched:
#   - hypr/hyprland.conf: wallpaper path → store path, Gentoo-only
#     gentoo-pipewire-launcher dropped, `light` → brightnessctl (light was
#     removed from nixpkgs)
#   - gtk-3.0/bookmarks: /home/matus → the actual home directory
# Skipped on purpose: files/neofetch (binary removed from nixpkgs; fastfetch
# replaces it), files/claude and files/BetterDiscord (personal/vendored).
{ config, pkgs, ... }:
let
  hyprlandConf =
    builtins.replaceStrings
      [
        "/home/matus/Dokumente/gitlab/personal/dots/Wallpapers"
        "exec-once = gentoo-pipewire-launcher\n"
        "light -A 5"
        "light -U 5"
      ]
      [
        "${../../Wallpapers}"
        ""
        "brightnessctl set 5%+"
        "brightnessctl set 5%-"
      ]
      (builtins.readFile ../../files/hypr/hyprland.conf);
in
{
  imports = [ ./fish.nix ];

  home.stateVersion = "26.05";
  programs.home-manager.enable = true;

  xdg.configFile = {
    "alacritty".source = ../../files/alacritty;
    "dunst".source = ../../files/dunst;
    "i3".source = ../../files/i3;
    "polybar".source = ../../files/polybar;
    "rofi".source = ../../files/rofi;
    "zellij".source = ../../files/zellij;
    "gtk-2.0".source = ../../files/gtk-2.0;
    "picom/picom.conf".source = ../../files/picom.conf;
    "libinput-gestures.conf".source = ../../files/libinput-gestures.conf;

    # lazy.nvim writes lazy-lock.json into the config dir — needs a real,
    # writable directory, not a store symlink.
    "nvim" = {
      source = ../../files/nvim;
      recursive = true;
    };

    "hypr/hyprland.conf".text = hyprlandConf;

    "gtk-3.0/settings.ini".source = ../../files/gtk-3.0/settings.ini;
    "gtk-3.0/bookmarks".text = ''
      file://${config.home.homeDirectory}/Dokumente
      file://${config.home.homeDirectory}/Downloads
    '';
  };

  # Closes the unpinned-session gap: the Gentoo setup shipped no .xinitrc.
  home.file.".xinitrc".text = ''
    exec i3
  '';

  home.packages = with pkgs; [
    # Wayland session tools exec'd by hyprland.conf
    swaybg
    waybar
    wofi
    hyprpaper
    hyprlock
    hypridle
    swayidle
    swaylock
    # i3 keybinds use pactl (pipewire-pulse serves it); hypr uses wpctl
    pulseaudio
    xorg.xrandr
    xorg.setxkbmap
    fastfetch
  ];

  programs.starship.enable = true;
}
