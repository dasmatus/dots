# Betterbird, packaged straight from upstream's own release tarball rather
# than nixpkgs.
#
# Why a tarball and not nixpkgs: nixpkgs carried `betterbird` built from
# source and dropped it for want of a maintainer willing to keep tracking
# upstream's Thunderbird-ESR-plus-patches churn. Upstream itself never
# stopped shipping releases — betterbird.eu still publishes a signed
# linux-x86_64 tarball every ESR cycle — so this follows the same fallback
# nixpkgs itself uses whenever building a Mozilla-derived browser or mail
# client from source is more than a repo wants to maintain: wrap the
# prebuilt release binary with autoPatchelfHook instead of compiling it,
# the way nixpkgs's own thunderbird-bin and firefox-bin packages do. Unlike
# those two, which split into an "-unwrapped" build plus a separate generic
# wrapFirefox pass, this stays one derivation: nothing else in this repo
# needs to reuse the wrapping step generically, so the split would only add
# indirection.
#
# Why the shared ~/.thunderbird profile is left alone: nix/home/proton/proton.nix
# points home-manager's `programs.thunderbird` at this package
# (`package = pkgs.betterbird;`) purely for Betterbird's StatusNotifierItem
# tray icon, which is what keeps mail arriving with no window open.
# home-manager's thunderbird module hardcodes its profile directory to
# `~/.thunderbird` no matter which package is actually configured, and
# Betterbird — being a Thunderbird rebrand at the profile-format level —
# reads and writes that exact tree unmodified. Nothing below renames or
# redirects that path, on purpose: doing so would split the profile
# home-manager writes prefs into from the one the running binary opens.
# tests/proton-calendar.nix pins exactly this assumption.
#
# Runtime library research (the tarball-contents report) came back with no
# missing-library findings, so autoPatchelfHook runs here with nothing
# beyond what it always assumes (glibc/libgcc, found on every Nix system
# closure). If a real build turns up an unresolved NEEDED entry, add the
# specific library `auto-patchelf` names in its own error rather than
# pre-emptively importing a generic Thunderbird dependency list nobody has
# confirmed against this particular tarball.
{
  lib,
  stdenv,
  pkgs,
  fetchurl,
  autoPatchelfHook,
  patchelfUnstable,
  makeWrapper,
  makeDesktopItem,
  alsa-lib,
  atk,
  cairo,
  dbus,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  pango,

}:

let
  version = "153.2.0esr-bb8";
  desktopItem = makeDesktopItem {
    name = "betterbird";
    exec = "betterbird %U";
    icon = "betterbird";
    desktopName = "Betterbird";
    genericName = "Email Client";
    comment = "Read and write e-mails or RSS feeds, or manage tasks on calendars";
    categories = [
      "Network"
      "Email"
    ];
    keywords = [
      "mail"
      "email"
      "e-mail"
      "calendar"
      "addressbook"
      "chat"
    ];
    mimeTypes = [
      "message/rfc822"
      "x-scheme-handler/mailto"
      "text/calendar"
      "text/x-vcard"
    ];
    actions.profile-manager-window = {
      name = "Profile Manager";
      exec = "betterbird --ProfileManager";
    };
  };
in
stdenv.mkDerivation {
  pname = "betterbird";
  inherit version;

  src = fetchurl {
    url = "https://www.betterbird.eu/downloads/LinuxArchive/betterbird-${version}.en-US.linux-x86_64.tar.xz";
    # Cross-checked against the upstream release's published sha256
    # (142ebb63d3f84c6d4a88252ced2c2dd2ce5d28eb3b08b05f10d841fe3d4f8001).
    hash = "sha256-FC67Y9P4TG1KiCUs7Swt0s5dKOs7CLBfENhB/j1PgAE=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    patchelfUnstable
    makeWrapper
  ];

  # Every entry here was named by a failing build, not guessed: the first
  # attempt shipped an empty list on the theory that the tarball was
  # self-contained, and auto-patchelf answered with 29 unresolved DT_NEEDED
  # entries across betterbird itself, vaapitest, librnp.so and rnp-cli. The
  # list below is exactly that set mapped to nixpkgs attributes, so adding to
  # it should mean a build told you to.
  #
  # stdenv.cc.cc.lib covers libstdc++.so.6 and libgcc_s.so.1, which the
  # bundled OpenPGP pieces (librnp.so, rnp-cli) want and which no other entry
  # here brings in.
  buildInputs = with pkgs; [
    alsa-lib
    atk
    cairo
    dbus
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    pango
    stdenv.cc.cc.lib
    libx11
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxcb
  ];

  # Betterbird inherits Firefox/Thunderbird's "relrhack", which manually
  # processes relocations from a fixed offset in the ELF section table;
  # patchelf's default section rewriting breaks that layout unless told to
  # leave old sections in place, and only the `patchelfUnstable` build
  # understands this flag. nixpkgs's own firefox-bin and thunderbird-bin
  # carry the identical flag for the identical reason.
  patchelfFlags = [ "--no-clobber-old-sections" ];

  dontConfigure = true;
  dontBuild = true;

  # Nix, not Betterbird, owns upgrades here — an in-place self-update would
  # write into the read-only store and just fail, noisily, on every launch.
  postPatch = ''
    echo 'pref("app.update.auto", "false");' >> defaults/pref/channel-prefs.js
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/betterbird"
    cp -r . "$out/lib/betterbird"

    mkdir -p "$out/bin"
    ln -s "$out/lib/betterbird/betterbird" "$out/bin/betterbird"

    # LD_LIBRARY_PATH points back at the install dir for the sake of any
    # sibling library Betterbird dlopen()s by bare name instead of a
    # DT_NEEDED entry (autoPatchelf only rewrites the latter); the
    # MOZ_* vars mirror what nixpkgs's own Mozilla wrapper always sets, and
    # MOZ_ENABLE_WAYLAND is a default rather than a hard set so a user who
    # needs XWayland can still override it.
    wrapProgram "$out/bin/betterbird" \
      --prefix LD_LIBRARY_PATH : "$out/lib/betterbird" \
      --set MOZ_APP_LAUNCHER betterbird \
      --set MOZ_LEGACY_PROFILES 1 \
      --set-default MOZ_ENABLE_WAYLAND 1

    install -m 644 -D -t "$out/share/applications" ${desktopItem}/share/applications/*

    # Mirrors upstream Mozilla tarballs: prefer a bundled icon theme tree if
    # this release ships one, else fall back to scavenging the
    # default<res>.png files Mozilla builds drop in the install dir by
    # convention. Either way, this is a no-op rather than a failure if the
    # tarball ships neither.
    if [ -e "$out/lib/betterbird/share/icons" ]; then
      mkdir -p "$out/share"
      ln -s "$out/lib/betterbird/share/icons" "$out/share/icons"
    else
      for res in 16 32 48 64 128; do
        icon=$(find "$out/lib/betterbird" -name "default''${res}.png" -print -quit)
        if [ -n "$icon" ]; then
          mkdir -p "$out/share/icons/hicolor/''${res}x''${res}/apps"
          ln -s "$icon" "$out/share/icons/hicolor/''${res}x''${res}/apps/betterbird.png"
        fi
      done
    fi

    runHook postInstall
  '';

  meta = {
    description = "Thunderbird fork restoring features upstream removed, with no telemetry";
    homepage = "https://www.betterbird.eu/";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "betterbird";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
