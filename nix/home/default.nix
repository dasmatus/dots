# home-manager profile aggregator. Fully native modules; the raw files/
# dotfile tree is gone (git history). Every former dotfile is either a native
# module imported below (kitty.nix, zellij.nix, fastfetch.nix, fish.nix,
# claude.nix, hyprland.nix, quickshell/, nixvim.nix,
# librewolf.nix, dots-repo.nix) or was deliberately dropped (BetterDiscord,
# Vesktop covers it; gtk-2.0 filechooser state). GUI apps that used to be
# flatpaks live in pkgs.nix with their configs. The only generated
# raw text left is gtk-3.0/bookmarks (needs the real home directory
# interpolated).
# The X11-era stack (i3, polybar, picom, libinput-gestures, swaybg wallpaper
# exec, swayidle/swaylock, redshift) has been fully replaced by the Wayland
# modules imported below. swayidle was the last of those to actually get a
# replacement: for a while this comment claimed it had one and nothing in the
# tree blanked or locked anything. The shell owns idle now
# (quickshell/qml/idle/), on ext-idle-notify-v1 rather than a daemon.
# The desktop shell is quickshell/: one QML tree where waybar, dunst, eww,
# rofi and beamenu used to be five programs with five theme paths.
#
# This file is now the NixOS-side aggregator only: the content moved into
# nix/home/profiles/{portable,session}.nix so a non-NixOS host can take the
# portable half alone (flake/home.nix). Importing both here reproduces the
# previous module set exactly, so nixosConfigurations.tokyonight is unchanged
# by the split.
{
  imports = [
    ./profiles/portable.nix
    ./profiles/session.nix
  ];
}
