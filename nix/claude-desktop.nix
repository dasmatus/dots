# Claude Desktop for Linux (beta), Anthropic's official Electron app,
# repackaged from the amd64 .deb in their apt repository.
#
# There is no nixpkgs package and no source: upstream ships only a Debian
# binary (https://code.claude.com/docs/en/desktop-linux). The apt route the
# docs describe has no NixOS analogue: a keyring in /usr/share/keyrings, a
# sources.list.d entry, `apt install`. So the .deb is fetched by digest
# and its bundled Electron is autoPatchelf'd against nixpkgs libraries.
#
# Bumping: the repo publishes every build in one flat index, so read the
# newest Version/SHA256 pair out of it and convert the hash to SRI:
#
#   curl -sS https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages \
#     | awk -v RS='' '/^Package: claude-desktop/' \
#     | grep -E '^(Version|SHA256):' | paste - - | sort -V | tail -1
#   nix hash convert --hash-algo sha256 --to sri <hex>
#
# The app is x86_64-only here by choice, not by upstream limit: the repo also
# publishes arm64, but this flake only ever evaluates x86_64-linux.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  cups,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libGL,
  libnotify,
  libsecret,
  libxkbcommon,
  libcap_ng,
  libgbm,
  libseccomp,
  nspr,
  nss,
  pango,
  systemdLibs,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libxrandr,
  libxcb,
  libxtst,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = "1.34493.1";

  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_amd64.deb";
    hash = "sha256-GYKXeWM6J3/NcqZYNCbGik7P96pDomcY1mRcLpVHR8o=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libGL
    libnotify
    libsecret
    libxkbcommon
    # Not Electron deps: the package bundles virtiofsd and cowork-linux-helper
    # under resources/ for the Cowork VM feature (mirroring the .deb's
    # `qemu-system-x86, ovmf, virtiofsd` Recommends), and autoPatchelf
    # resolves those binaries too.
    libcap_ng
    libseccomp
    libgbm
    nspr
    nss
    pango
    systemdLibs
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libxrandr
    libxcb
    libxtst
  ];

  unpackCmd = "dpkg-deb -x $curSrc source";
  sourceRoot = "source";

  # The GApps hook must wrap the real Electron binary, not the launcher
  # makeWrapper writes in installPhase. Otherwise the GTK/pixbuf env lands
  # on the outer script and is then clobbered by the inner exec.
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib $out/share
    cp -r usr/lib/claude-desktop $out/lib/
    cp -r usr/share/applications usr/share/icons $out/share/

    # chrome-sandbox ships setuid-root and cannot be one in the store. Electron
    # falls back to the unprivileged-userns sandbox, which NixOS allows; drop
    # the mode bits so autoPatchelf doesn't trip over a file it can't rewrite.
    chmod u+w $out/lib/claude-desktop/chrome-sandbox

    makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      --add-flags "--ozone-platform-hint=auto" \
      --add-flags "--enable-features=WaylandWindowDecorations"

    substituteInPlace $out/share/applications/com.anthropic.Claude.desktop \
      --replace-quiet "/usr/bin/claude-desktop" "$out/bin/claude-desktop" \
      --replace-quiet "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

    runHook postInstall
  '';

  meta = {
    description = "Official Claude desktop app (Chat, Cowork and Claude Code)";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    mainProgram = "claude-desktop";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
