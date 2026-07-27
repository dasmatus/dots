# home-manager profile aggregator — fully native modules; the raw files/
# dotfile tree is gone (git history). Every former dotfile is either a native
# module imported below (kitty.nix, zellij.nix, fastfetch.nix, fish.nix,
# claude.nix, hyprland.nix, waybar.nix, wallpaper-tui.nix, dunst.nix, eww/, rofi/,
# nixvim.nix, librewolf.nix, dots-repo.nix) or was deliberately dropped (BetterDiscord —
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
    ./kitty.nix
    ./zellij.nix
    ./fastfetch.nix
    ./fish.nix
    ./claude.nix
    ./codex.nix
    ./computer-use-linux.nix
    ./nixvim.nix
    ./dokumente.nix
    ./dots-repo.nix
    ./brave.nix
    ./junction.nix
    ./hyprland.nix
    ./hyprmon.nix
    ./waybar.nix
    ./wallpaper-tui.nix
    ./dunst.nix
    ./keybinds.nix
    ./random_wp.nix
    ./librewolf.nix
    ./eww
    ./rofi
    ./git.nix
    ./bitwarden.nix
    ./proton.nix
    ./pkgs.nix
    ./vscode.nix
  ];
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;

  # computer-use-linux MCP server + CLI, registered into every harness
  # present here (Claude Code + Codex). See nix/home/computer-use-linux.nix.
  programs.computer-use-linux.enable = true;
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
    # Wayland wallpaper daemon (renamed swww) exec'd by wallpaper-tui via
    # `awww img` for animated transitions; random_wp.nix routes through
    # wallpaper-tui so it inherits awww too. awww-daemon is started at
    # hyprland.start (hyprland.nix).
    awww
    brightnessctl
  ];

  # Declarative wallpaper config consumed by wallpaper-tui.nix. Runtime picks
  # made in the TUI override these per output in writable state; to make a
  # pick permanent, edit `outputs.eDP-1.path` here and rebuild.
  programs.wallpaper-tui = {
    enable = true;
    currentOutput = "eDP-1";
    outputs.eDP-1.path = "${config.home.homeDirectory}/Dokumente/codeberg/personal/dots/Wallpapers/wh/wallhaven-k81776.jpg";
  };
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
    # wallpaper-tui accent tint: each extraCss @imports a runtime-state file
    # (~/.local/state/wallpaper-tui/tint/gtkN.css) that the Python script
    # writes after every wallpaper change. HM appends extraCss AFTER the
    # Tokyonight theme @import, so the @define-color overrides win. If the
    # state file doesn't exist yet (fresh boot, before the first tint), GTK
    # logs a CSS warning and falls back to the base theme — corrected within
    # seconds by the wallhaven-wallpaper login service / wallpaper-tui --restore.
    gtk3.extraCss = ''
      @import url("file://${config.xdg.stateHome}/wallpaper-tui/tint/gtk3.css");
    '';
    gtk4.extraCss = ''
      @import url("file://${config.xdg.stateHome}/wallpaper-tui/tint/gtk4.css");
    '';
    iconTheme = {
      name = "MoreWaita";
      package = pkgs.morewaita-icon-theme;
    };
  };
  programs.starship.enable = true;
}
