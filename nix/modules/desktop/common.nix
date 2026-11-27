# System-level desktop services shared by all three DEs (GNOME, Hyprland,
# Sway). Everything here is unconditional — no `if` on the DE choice. Each
# per-DE module (gnome.nix, hyprland.nix, sway.nix) adds only what is unique
# to its compositor.
#
# Split out of the former desktop.nix monolith so a second DE can be added
# without duplicating pipewire/fonts/portals.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  config = lib.mkMerge [
    {
      services.gnome.gnome-keyring.enable = true;
      # GUI frontend for gnome-keyring (also wires ssh askpass). This is a
      # NixOS option, not a home-manager one.
      programs.seahorse.enable = true;

      services.udisks2.enable = true;

      # Nothing added for exfat or vfat: both are already in
      # /proc/filesystems on this machine and udisks mounts them through
      # the kernel driver without running fsck. ntfs is different.
      # udisks lists "ntfs" in its SupportedFilesystems D-Bus property,
      # but it ships no mount.ntfs of its own, so that property is not
      # proof the kernel can actually mount one.
      boot.supportedFilesystems.ntfs = true;

      # UPower backs the Quickshell bar's battery module. waybar read
      # /sys/class/power_supply itself and so needed nothing here, which is
      # why this was never enabled; Quickshell talks to
      # org.freedesktop.UPower over D-Bus instead, and without the service
      # the name is not activatable and the battery silently never appears.
      # The daemon also supplies charge state and time-to-empty, which
      # sysfs only offers as raw counters to be reassembled by hand.
      services.upower.enable = true;

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

      programs.dconf.enable = true;

      # The SYSTEM-level half of Flatpak (nixpkgs' own
      # nixos/modules/services/desktops/flatpak.nix — the plain
      # `services.flatpak.enable`, not nix-flatpak's declarative
      # packages/overrides, which stay on the home-manager side; see
      # nix/home/base/flatpaks.nix's header for why). Installing Flathub refs
      # into the USER installation without this one line still works —
      # flatpak run resolves them fine — but their exports/share never
      # joins the system XDG_DATA_DIRS, so a Flatpak's own icons, mime
      # associations and D-Bus service files are invisible to anything that
      # only ever looks at the system search path.
      services.flatpak.enable = true;
    }
  ];
}
