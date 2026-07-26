# Non-install-time parameters with defaults. flake.nix merges this file
# *under* nix/settings.nix:
#   settings = (import ./nix/defaults.nix) // (import ./nix/settings.nix);
# The installer TUI (rust/installer-tui/src/config.rs::settings_nix) rewrites only
# the four install answers (username/hostname/disks/swapSize) into settings.nix
# on the target, so anything it does not write must live here to survive an
# install — otherwise the installer would wipe it and the modules that read
# settings.<key> would lose their values on the next rebuild. Edit this file
# in the installed clone (~/Dokumente/.../dots/nix/defaults.nix) to change
# regional, desktop, boot, and network choices; it is git-tracked and travels
# with the user's clone, so edits persist across autoUpgrade (which only
# refreshes flake.lock, not this file).
{
  # Regional — consumed by nix/modules/core.nix.
  timezone = "Europe/Bratislava";
  locale = "de_DE.UTF-8";

  # Desktop environment — consumed by nix/modules/desktop.nix. The whole
  # system-level desktop block is gated on this being "hyprland"; "none" (or
  # any other value) skips it. NOTE: the Home Manager side (nix/home) is not
  # conditional on this — settings is not passed to home-manager (users.nix
  # passes only `inputs` via extraSpecialArgs), so a non-"hyprland" value here
  # leaves the home hyprland config in place. Wire HM separately if a second
  # desktop is ever added.
  desktop = "hyprland";

  # Boot knobs — consumed by nix/modules/boot.nix.
  plymouthTheme = "rings";
  zswapCompressor = "842";
  # Merged (list-concat) with the hardening params in nix/modules/hardening.nix
  # and the serial-console params in nix/iso.nix (ISO only).
  bootKernelParams = [
    "quiet"
    "loglevel=3"
    "mitigations=auto"
  ];

  # Network — consumed by nix/modules/network.nix. wifiBackend is one of
  # "wpa_supplicant" | "iwd"; reversePathFilter is one of "loose" | "strict"
  # (or false) — see networking.firewall.checkReversePath in nixpkgs.
  wifiBackend = "wpa_supplicant";
  reversePathFilter = "loose";
}
