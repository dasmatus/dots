# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# the hyprtile suite and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  ...
}:
self: {
  # HyprTile (https://hyprtile.org) — the fullscreen tile launcher + tool
  # suite for Hyprland that the desktop stack is converted to (launcher,
  # settings/config center, screenshots, wallpaper daemon). Upstream ships a
  # source zip and a sudo-to-/usr/local install.sh; here only the pieces the
  # dots stack uses are built — launcher, wallpaperd, shotter, screener and
  # the small helper tools — skipping the heavy TTS/STT/XMPP/videoplayer/
  # remoteviewer subprojects. nix/home/hyprtile.nix wraps the store path.
  hyprtile = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "hyprtile";
    version = "0.16";
    src = pkgs.fetchurl {
      url = "https://hyprtile.org/file/695476a2a14981a8720b";
      name = "hyprtile-v${finalAttrs.version}.zip";
      hash = "sha256-YrGB1sVBMp+j9OTIhOD9zSEg0A7g6ahiiPMeo2Vuox4=";
    };
    sourceRoot = "hyprtile";
    nativeBuildInputs = with pkgs; [
      unzip
      pkg-config
      wayland-scanner
    ];
    buildInputs = with pkgs; [
      sdl3
      sdl3-ttf
      librsvg
      libepoxy
      glib
      fontconfig
      libpulseaudio
      fftw
      ffmpeg
      libsodium
      wayland
      libglvnd
      libpng
    ];
    # Upstream printf()s translated strings (tr("key")) as format strings,
    # which nix cc-wrapper's -Werror=format-security rejects.
    hardeningDisable = [ "format" ];
    # The icon lookup falls back to the install.sh location; point it at the
    # store instead. User icons under ~/.hyprtile/icons still take priority.
    postPatch = ''
      substituteInPlace ui_icons.c \
        --replace-fail "/usr/local/share/hyprtile/icons" "$out/share/hyprtile/icons"
    '';
    enableParallelBuilding = true;
    buildPhase = ''
      runHook preBuild
      protoFlags="WLR_PROTO_DIR=${pkgs.wlr-protocols}/share/wlr-protocols/unstable \
        WAYLAND_PROTO_DIR=${pkgs.wayland-protocols}/share/wayland-protocols/stable/xdg-shell"
      make -C hyprtile-screener-build $protoFlags
      make -C hyprtile-shotter $protoFlags
      make hyprtile hyprtile-wallpaperd hyprtile-setaudiovol hyprtile-setbrightness \
        hyprtile-batterystat hyprtile-bt hyprtile-notes/hyprtile-notes \
        hyprtile-pwsafe/hyprtile-pwsafe hyprtile-ai
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 -t $out/bin \
        hyprtile hyprtile-wallpaperd hyprtile-setaudiovol hyprtile-setbrightness \
        hyprtile-batterystat hyprtile-bt hyprtile-shotter/hyprtile-shotter \
        hyprtile-screener-build/hyprtile-screener hyprtile-notes/hyprtile-notes \
        hyprtile-pwsafe/hyprtile-pwsafe hyprtile-ai
      mkdir -p $out/share/hyprtile
      cp -r icons languages config.json example-configs $out/share/hyprtile/
      runHook postInstall
    '';
    meta = {
      description = "Fullscreen tile-based launcher and command center for Hyprland";
      homepage = "https://hyprtile.org/";
      license = pkgs.lib.licenses.gpl3Plus;
      mainProgram = "hyprtile";
      platforms = pkgs.lib.platforms.linux;
    };
  });
  dots-installer = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-installer";
    version = "0.1.0";
    src = ../rust/installer-tui;
    cargoLock.lockFile = ../rust/installer-tui/Cargo.lock;
  };
  # Built once at the flake level (was inline in nix/home/wallpaper-tui.nix)
  # so `nix build .#wallpaper-tui` works, the cache key is shared, and the
  # home module just wraps the store path instead of re-evaluating the crate.
  wallpaper-tui = pkgs.rustPlatform.buildRustPackage {
    pname = "wallpaper-tui";
    version = "0.1.0";
    src = ../rust/wallpaper-tui;
    cargoLock.lockFile = ../rust/wallpaper-tui/Cargo.lock;
    meta.mainProgram = "wallpaper-tui";
  };
  settings = pkgs.rustPlatform.buildRustPackage {
    pname = "settings";
    version = "0.1.0";
    src = ../rust/settings-global;
    cargoLock.lockFile = ../rust/settings-global/Cargo.lock;
    # The crate is named global-settings, so `nix run .#settings` needs the
    # binary spelled out.
    meta.mainProgram = "global-settings";
  };
  # hyprmon — the declarative multi-monitor auto-detection daemon. Built at
  # the flake level for the same reasons as wallpaper-tui (cache key sharing,
  # `nix build .#hyprmon`); nix/home/hyprmon.nix wraps the store path and
  # wires the systemd user service.
  hyprmon = pkgs.rustPlatform.buildRustPackage {
    pname = "hyprmon";
    version = "0.1.0";
    src = ../rust/hyprmon;
    cargoLock.lockFile = ../rust/hyprmon/Cargo.lock;
    meta.mainProgram = "hyprmon";
  };
  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/aipage.nix. Consumed by the LibreWolf and Brave home
  # modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;
  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;
}
