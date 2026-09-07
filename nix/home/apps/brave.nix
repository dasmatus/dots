# Brave, as a Flathub flatpak (com.brave.Browser, declared in
# nix/home/base/flatpaks.nix) rather than nixpkgs' package.
#
# `programs.brave` is therefore NOT used any more. That module's only job was
# to install the package and render `brave-flags.conf`; the package now comes
# from Flathub, and the flags file has to move — a flatpak reads
# $XDG_CONFIG_HOME from inside its sandbox, which is
# ~/.var/app/com.brave.Browser/config, not ~/.config. Enabling the module
# alongside the flatpak would install a second, native Brave and write the
# flags where the flatpak cannot see them, so the file is written directly
# below instead.
{
  config,
  lib,
  pkgs,
  aipageChrome,
  ...
}:
let
  # Everything a flatpak sees as $XDG_CONFIG_HOME / $HOME lives under this
  # per-app root. Spelled once here because three paths below derive from it.
  appId = "com.brave.Browser";
  appConfig = "${config.home.homeDirectory}/.var/app/${appId}/config";
in
{
  # AIPage (EduPage AI sidebar — codeberg.org/dasmatus/aipage), built inside
  # this flake from a pinned fetchGit source (see nix/packages/aipage.nix +
  # flake.nix packages.aipage-chrome). `aipageChrome` is the unpacked MV2
  # dist dir (a store path).
  #
  # Brave 1.92.139 segfaults on startup (jump through a NULL pointer, ip=0)
  # when its runtime-dlopened GTK integration picks GTK4 on a Wayland
  # session — bisected: --ozone-platform=x11 runs, wayland+gtk4 crashes,
  # wayland+gtk3 runs. Pin the GTK3 path until the upstream GTK4/Wayland
  # shim works against GTK 4.22.
  #
  # --load-extension: Chromium has no policy to force-install an *unpacked*
  # MV2 extension without a hosted CRX + update_url, so --load-extension is
  # the declarative equivalent: it reloads the unpacked dir on every launch.
  #
  # NB the extension path is a /nix/store path being handed to a sandboxed
  # app. The store is not in a flatpak's default filesystem set, which is why
  # nix/home/base/flatpaks.nix grants this app read-only access to it — and
  # why that grant is load-bearing rather than cosmetic: without it Brave
  # starts with no AIPage and no error a user would notice.
  home.file."${appConfig}/brave-flags.conf".text = ''
    --gtk-version=3
    --load-extension=${aipageChrome}
  '';

  # Appearance "GTK" mode has no browser policy and no HM option: the choice
  # lives per-profile in Preferences → extensions.theme.system_theme
  # (ui::SystemTheme::kGtk = 1). Assert it on activation so Brave's chrome
  # follows the GTK theme. No-op before Brave's first launch; a Brave exit
  # during a switch may rewrite the file, so the next switch re-asserts it.
  # Default profile only.
  #
  # The profile moved with the package: a flatpak Brave keeps its user data
  # under the per-app root, not ~/.config/BraveSoftware.
  home.activation.braveGtkTheme = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    prefs=${lib.escapeShellArg "${appConfig}/BraveSoftware/Brave-Browser/Default/Preferences"}
    if [ -f "$prefs" ] && ! ${lib.getExe pkgs.jq} -e '.extensions.theme.system_theme == 1' "$prefs" >/dev/null; then
      run sh -c '${lib.getExe pkgs.jq} ".extensions.theme.system_theme = 1" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' sh "$prefs"
    fi
  '';
}
