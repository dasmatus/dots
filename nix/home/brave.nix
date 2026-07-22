{
  config,
  lib,
  pkgs,
  ...
}:
let
  # AIPage (EduPage AI sidebar — codeberg.org/dasmatus/aipage), built from
  # source in the sibling aipage repo. The gitignored dist-chrome dir can't
  # be a flake input (path inputs outside this flake aren't store-copied),
  # so a deterministic tarball of it lives at
  # ~/.local/share/aipage/dist-chrome.tar and is pulled in here as an
  # eval-time fixed-output derivation (builtins.fetchTarball fetches outside
  # the build sandbox, so sandbox=true is fine). Bump the sha256 when aipage
  # is rebuilt (see scripts/update-aipage.sh).
  aipageChrome = builtins.fetchTarball {
    url = "file://${config.home.homeDirectory}/.local/share/aipage/dist-chrome.tar";
    sha256 = "0zvhcav57ixb9dnq58xzy8gb095zc9vhq5izqmx6m1iz6rk7j0x5";
  };
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
    # --load-extension: AIPage, the unpacked MV2 extension from the tarball
    # above. Chromium has no policy to force-install an *unpacked* MV2
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
