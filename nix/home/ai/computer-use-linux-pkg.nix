# Prebuilt computer-use-linux MCP server + CLI (github.com/agent-sh/computer-use-linux).
# Upstream ships no flake, so we wrap the official x86_64-unknown-linux-gnu
# release binary with autoPatchelfHook, which rewrites the ELF interpreter
# and rpath to Nix-store glibc/libgcc, the standard way to Nixify an upstream
# release binary without recompiling. The binary only links glibc at load
# time: zbus (DBus) is pure Rust, and AT-SPI is reached over the session
# DBus rather than via a linked .so, so no extra buildInputs are needed.
#
# Runtime desktop control is NOT satisfied by this package alone. The MCP
# stdio server registers and lists tools without any system deps, but
# actually *calling* the tools needs: ydotoold (input injection), the AT-SPI
# bus (accessibility tree), xdg-desktop-portal (screenshots), and a udev
# rule giving the input group access to /dev/uinput. Run `computer-use-linux
# doctor | jq .readiness` after switching to see what's missing on this box.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  libgcc,
}:
let
  version = "0.4.1";
  asset = "computer-use-linux-x86_64-unknown-linux-gnu";
in
stdenv.mkDerivation {
  pname = "computer-use-linux";
  inherit version;
  src = fetchurl {
    url = "https://github.com/agent-sh/computer-use-linux/releases/download/v${version}/${asset}";
    # Cross-checked against the upstream .sha256 sibling asset
    # (b94800233bad955952c3f12065069b345740b3011e1cfa115fa956e6b533fe1f).
    hash = "sha256-uUgAIzutlVlSw/EgZQabNFdAswEeHPoRX6lW5rUz/h8=";
  };
  # src is the bare release binary (not a tarball), so skip unpack and
  # autoPatchelf it in-place during install. autoPatchelfHook scans
  # $prefix/bin and rewrites the ELF interpreter/rpath to Nix-store libs.
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  # The binary links libgcc_s.so.1; autoPatchelf needs libgcc on the rpath
  # to satisfy it (glibc itself is auto-added). zbus/AT-SPI are pure Rust /
  # DBus-reached, so nothing else is linked.
  buildInputs = [ libgcc ];
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" $out/bin/computer-use-linux
    autoPatchelf $out/bin/computer-use-linux
    runHook postInstall
  '';
  meta = {
    description = "MCP server + CLI that lets an AI agent drive a real Linux desktop (Wayland-first, X11 best-effort)";
    homepage = "https://github.com/agent-sh/computer-use-linux";
    license = lib.licenses.mit;
    mainProgram = "computer-use-linux";
    platforms = [ "x86_64-linux" ];
  };
}
