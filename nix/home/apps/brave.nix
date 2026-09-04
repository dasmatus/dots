{
  config,
  lib,
  pkgs,
  aipageChrome,
  ...
}:
let
  # AIPage (EduPage AI sidebar — codeberg.org/dasmatus/aipage), built inside
  # this flake from a pinned fetchGit source (see nix/packages/aipage.nix +
  # flake.nix packages.aipage-chrome). `aipageChrome` is the unpacked MV2
  # dist dir (a store path) — no tarball, no local-file FOD, so it works on
  # the installer ISO.
in
{
  programs.brave = {
    enable = true;

    # Brave 1.92.139 segfaults on startup (jump through a NULL pointer, ip=0)
    # when its runtime-dlopened GTK integration picks GTK4 on a Wayland
    # session — bisected: --ozone-platform=x11 runs, wayland+gtk4 crashes,
    # wayland+gtk3 runs. Pin the GTK3 path until the upstream GTK4/Wayland
    # shim works against nixpkgs' GTK 4.22.
    #
    # --load-extension: AIPage, the unpacked MV2 extension from the
    # aipageChrome store path (built in-flake, see nix/packages/aipage.nix). Chromium
    # has no policy to force-install an *unpacked* MV2
    # extension without a hosted CRX + update_url, so --load-extension is
    # the declarative equivalent: it reloads the unpacked dir on every
    # launch. Cost is a "developer mode extensions" banner on startup; the
    # extension itself (MV2) loads fine as long as Brave keeps MV2 support.
    commandLineArgs = [
      "--gtk-version=3"
      "--load-extension=${aipageChrome}"
    ];
  };

  # Appearance "GTK" mode has no browser policy and no HM option: the choice
  # lives per-profile in Preferences → extensions.theme.system_theme
  # (ui::SystemTheme::kGtk = 1). Assert it on activation so Brave's chrome
  # follows Tokyonight-Dark GTK3 — the same palette kitty.nix hardcodes.
  # No-op before Brave's first launch; a Brave exit during a switch may
  # rewrite the file, so the next switch re-asserts it. Default profile only.
  home.activation.braveGtkTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    prefs=${lib.escapeShellArg "${config.xdg.configHome}/BraveSoftware/Brave-Browser/Default/Preferences"}
    if [ -f "$prefs" ] && ! ${lib.getExe pkgs.jq} -e '.extensions.theme.system_theme == 1' "$prefs" >/dev/null; then
      run sh -c '${lib.getExe pkgs.jq} ".extensions.theme.system_theme = 1" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh "$prefs"
    fi
  '';
}
