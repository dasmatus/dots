{
  lib,
  pkgs,
  rustPlatform,
}:
# Tauri v2 screenshot overlay (Snipping Tool-style) — the grim-backed
# replacement for the HyprCapture plugin. Built with the same
# `rustPlatform.buildRustPackage` pattern as `dots-installer`, plus the
# webkit2gtk-4.1 / gtk3 stack Tauri v2 links against on Linux. `wrapGAppsHook`
# puts the GI typelibs and webkit2gtk runtime env on the binary's wrapper so
# the webview starts under Home Manager without a system session env.
rustPlatform.buildRustPackage {
  pname = "dots-snip";
  version = "0.1.0";
  src = ../snip;
  cargoLock.lockFile = ../snip/Cargo.lock;

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.gobject-introspection
    pkgs.wrapGAppsHook3
  ];

  buildInputs = [
    pkgs.webkitgtk_4_1
    pkgs.gtk3
    pkgs.librsvg
    pkgs.glib
    pkgs.cairo
    pkgs.pango
    pkgs.gdk-pixbuf
    pkgs.openssl
  ];

  meta = with lib; {
    description = "Snipping Tool-style screenshot overlay for Hyprland, backed by grim";
    license = licenses.mit;
    mainProgram = "dots-snip";
  };
}