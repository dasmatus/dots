# Brave, back as a native package (the Gentoo-era install predated the NixOS
# migration — fish.nix still notes its orphaned BROWSER variable). nixpkgs'
# brave is MPL-2.0 (repackaged official .deb), so no allowUnfree needed.
# Chromium ≥14x auto-selects Ozone/Wayland on Wayland sessions regardless of
# NIXOS_OZONE_WL, so no wrapper flag is needed for that either.
#
# All policy lives system-side in nix/modules/desktop.nix
# (/etc/brave/policies/managed): the long-standing hardening set plus the
# full Brave Origin feature-strip (Rewards/Wallet/VPN/Tor/Leo/News/Talk/
# Playlist/Speedreader/Wayback/Web Discovery/P3A/stats ping all off). Brave
# Origin's consumer "Upgrade" toggle (brave://settings > System, free on
# Linux) flips exactly those policies through its internal Origin policy
# manager, and the standalone brave-origin package isn't in nixpkgs — so
# managed policies ARE the declarative way to run Origin here.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.brave = {
    enable = true;

    # Brave 1.92.139 segfaults on startup (jump through a NULL pointer, ip=0)
    # when its runtime-dlopened GTK integration picks GTK4 on a Wayland
    # session — bisected: --ozone-platform=x11 runs, wayland+gtk4 crashes,
    # wayland+gtk3 runs. Pin the GTK3 path until the upstream GTK4/Wayland
    # shim works against nixpkgs' GTK 4.22.
    commandLineArgs = [ "--gtk-version=3" ];
  };

  # Appearance "GTK" mode has no browser policy and no HM option: the choice
  # lives per-profile in Preferences → extensions.theme.system_theme
  # (ui::SystemTheme::kGtk = 1). Assert it on activation so Brave's chrome
  # follows Tokyonight-Dark GTK3 — the same palette alacritty.nix hardcodes.
  # No-op before Brave's first launch; a Brave exit during a switch may
  # rewrite the file, so the next switch re-asserts it. Default profile only.
  home.activation.braveGtkTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    prefs=${lib.escapeShellArg "${config.xdg.configHome}/BraveSoftware/Brave-Browser/Default/Preferences"}
    if [ -f "$prefs" ] && ! ${lib.getExe pkgs.jq} -e '.extensions.theme.system_theme == 1' "$prefs" >/dev/null; then
      run sh -c '${lib.getExe pkgs.jq} ".extensions.theme.system_theme = 1" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh "$prefs"
    fi
  '';
}
