# HyprCapture — a Hyprland-only screenshot/recording overlay plugin
# (https://github.com/gfhdhytghd/HyprCapture). Unlike Flameshot (a plain
# nixpkgs package), this is a *compositor plugin*: it builds a
# `libhyprcapture.so` that Hyprland dlopen()s plus a `hyprcapture-ui` Qt6
# helper the plugin shells out to for the region/window overlay. Packaged
# with nixpkgs' `mkHyprlandPlugin` (re-exported from `hyprlandPlugins`),
# which auto-provides `pkg-config` + the matching `hyprland` dev headers —
# so `pkg_check_modules(HYPR_DEPS hyprland)` in CMakeLists resolves without
# us passing `hyprland` ourselves.
#
# Tag `v0.2.4-0.55.4` is the upstream release pinned to Hyprland 0.55.4,
# which is exactly the version this flake's nixos-unstable nixpkgs resolves
# to (nix eval nixpkgs#hyprland.version → 0.55.4). Hyprland enforces plugin
# ABI match at *load* time, not build time, and since both the plugin and
# the compositor come from the same flake their commit hashes agree, so the
# plugin loads without pinning the flake's hyprland input. The `hyprpm.toml`
# `commit_pins = [["0.54.3", ""]]` is irrelevant here — that's only read by
# the `hyprpm` runtime plugin manager, not by this Nix build.
#
# CMakeLists ships proper `install(TARGETS hyprcapture LIBRARY DESTINATION
# ${CMAKE_INSTALL_LIBDIR})` and `install(TARGETS hyprcapture-ui RUNTIME
# DESTINATION ${CMAKE_INSTALL_BINDIR})` rules, so the standard
# cmakeInstallPhase places the .so at $out/lib/libhyprcapture.so (the exact
# path Home Manager's `plugins` option expects: $out/lib/lib${pname}.so)
# and the helper at $out/bin/hyprcapture-ui — no manual installPhase. The
# `hyprpm.toml`'s manual `install -Dm755 …hyprcapture-ui` only exists
# because the hyprpm build path doesn't run `cmake --install`.
{
  lib,
  cmake,
  fetchFromGitHub,
  hyprland,
  mkHyprlandPlugin,
  lua5_5,
  glib,
  nlohmann_json,
  qt6,
  kdePackages,
  wl-clipboard,
  nix-update-script,
}:
mkHyprlandPlugin (finalAttrs: {
  pluginName = "hyprcapture";
  version = "0.2.4-0.55.4";

  src = fetchFromGitHub {
    owner = "gfhdhytghd";
    repo = "HyprCapture";
    tag = "v${finalAttrs.version}";
    hash = "sha256-KoPr8KykCeyCoFzg25PEMtZRIJxcpfdwk/uL//Wt6lc=";
  };

  # mkHyprlandPlugin already prepends pkg-config (native) and
  # hyprland + hyprland.buildInputs (build) — do not re-add them.
  nativeBuildInputs = [
    cmake
    kdePackages.extra-cmake-modules # find_package(LayerShellQt) needs ECM's CMake configs
    qt6.wrapQtAppsHook # wraps hyprcapture-ui so Qt platforms/plugins resolve at runtime
  ];

  buildInputs = [
    lua5_5 # pkg_check_modules(LUA REQUIRED lua) — ships lua.pc
    glib # gio-2.0 + gio-unix-2.0
    nlohmann_json # find_package(nlohmann_json)
    qt6.qtbase # Qt6::Core/Gui/Widgets/DBus
    qt6.qtsvg # Qt6::Svg
    kdePackages.layer-shell-qt # find_package(LayerShellQt) → LayerShellQt::Interface
    wl-clipboard # runtime dep of hyprcapture-ui (wl-copy/wl-paste) — wrapped onto PATH below
  ];

  # hyprcapture-ui shells out to wl-copy/wl-paste; wrapQtAppsHook puts this
  # prefix on its PATH. (The plugin locates the helper via HYPRCAPTURE_HELPER,
  # set in nix/home/hyprland.nix — it does NOT search $PATH.)
  qtWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ wl-clipboard ])
  ];

  # Skip the ctest test executables (include(CTest) enables BUILD_TESTING by
  # default); they have no install rules and only slow the build.
  cmakeFlags = [ "-DBUILD_TESTING=OFF" ];

  dontStrip = true; # matches hy3 — plugin is loaded into Hyprland's process

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Hyprland-only screenshot/recording overlay plugin";
    homepage = "https://github.com/gfhdhytghd/HyprCapture";
    license = lib.licenses.gpl3Plus;
    inherit (hyprland.meta) platforms;
    maintainers = [ ];
  };
})