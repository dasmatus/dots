# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# the beamenu launcher (view + binary), Claude Desktop and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  pkgsClaude,
  ...
}:
self: {
  # beamenu-view — bemenu carrying the beamenu patch series (nix/patches/beamenu).
  #
  # This is the VIEW half of the launcher, not a user-facing program: it ships
  # libbemenu plus the renderers, and `beamenu` below links against it. The
  # patches add what a Raycast-style row needs and stock bemenu has no model
  # for — per-item icon, subtitle, accessory and section heading, drawn as a
  # rounded-pill row — plus an eventfd in the renderer's existing epoll set so
  # asynchronous providers can push results into a blocked frame.
  #
  # Why patch bemenu rather than drive it over a pipe: bemenu's event loop is
  # client-owned. client/bemenu.c is 80 lines around run_menu(), which loops on
  # bm_menu_run_with_events() and returns after every keystroke, so the Rust
  # binary can simply *be* the client — no IPC protocol, no second process.
  #
  # librsvg is a new buildInput: the row renderer decodes SVG icons through it
  # and PNG through cairo, covering what XDG icon themes ship without taking on
  # gdk-pixbuf's runtime loader-module discovery.
  #
  # Built with clang rather than the stdenv default, over ThinLTO with hidden
  # visibility, linked by lld. lld arrives as the stdenv's *wrapped* bintools,
  # never through -fuse-ld=lld; see the note on preBuild below for why that
  # distinction is load-bearing.
  #
  # Control-Flow Integrity is deliberately NOT enabled, after trying three
  # ways. bemenu's renderers are dlopen()ed plugins called through dlsym'd
  # function pointers, which is precisely what cfi-icall forbids:
  #
  #   -fsanitize=cfi                  builds clean, then every single run dies
  #                                   on SIGILL from CFI's ud2 trap. Even
  #                                   `bemenu --version`. Stock nixpkgs bemenu
  #                                   prints its version and exits 0, so this
  #                                   was ours, not upstream's.
  #   + -fsanitize-cfi-cross-dso      runs correctly (each DSO exports
  #                                   __cfi_check), but leaves __cfi_slowpath
  #                                   undefined in libbemenu.so. Every consumer
  #                                   then has to supply compiler-rt, and the
  #                                   Rust `beamenu` crate links through gcc's
  #                                   cc, so `nix build .#beamenu` fails at
  #                                   link with "undefined reference to
  #                                   __cfi_slowpath".
  #   + -shared-libsan                does not help; the symbol stays U and no
  #                                   clang_rt DT_NEEDED is added.
  #
  # Shipping a launcher that traps on startup, or one whose own client cannot
  # link, is worse than shipping one without CFI. Anyone reopening this needs a
  # plan for the runtime symbol reaching a gcc-linked Rust consumer, and should
  # verify by RUNNING the binary, not by watching the build go green.
  #
  # 06-filter-pills.patch adds one C++ translation unit
  # (lib/renderers/pills.cpp, the bar's scroll geometry), which is why CXXFLAGS
  # matter here at all; bemenu's GNUmakefile pins it to -std=c++23, the newest
  # standard clang 21 implements in full rather than in part.
  beamenu-view = (pkgs.bemenu.override {
    stdenv = pkgs.overrideCC pkgs.clangStdenv (
      pkgs.clangStdenv.cc.override { bintools = pkgs.llvmPackages.bintools; }
    );
  }).overrideAttrs (old: {
    pname = "beamenu-view";
    patches = (old.patches or [ ]) ++ [
      ../nix/patches/beamenu/01-item-richtext.patch
      ../nix/patches/beamenu/02-cairo-raycast-rows.patch
      ../nix/patches/beamenu/03-panel-chrome.patch
      ../nix/patches/beamenu/04-client-ranking.patch
      ../nix/patches/beamenu/05-rich-panel-body.patch
      ../nix/patches/beamenu/06-filter-pills.patch
    ];
    buildInputs = old.buildInputs ++ [ pkgs.librsvg ];
    # lld arrives as the stdenv's *wrapped* bintools (above), never as
    # -fuse-ld=lld. That flag makes clang invoke ld.lld directly and step around
    # nixpkgs' bintools-wrapper, which is what injects a -rpath per buildInput.
    # The package still builds and installs; the renderer plugins then carry a
    # RUNPATH holding only bemenu's own lib dir, so every dlopen() fails at
    # runtime with "libcairo.so.2: cannot open shared object file" and the
    # launcher comes up with no renderer at all. Nothing in the build catches
    # it; compare `readelf -d` on a renderer .so against stock nixpkgs bemenu.
    #
    # makeFlagsArray, not makeFlags: the value contains spaces, and makeFlags
    # entries are word-split before they reach make.
    preBuild = (old.preBuild or "") + ''
      makeFlagsArray+=("LDFLAGS=-flto=thin -fvisibility=hidden")
    '';
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = "-flto=thin -fvisibility=hidden";
    };
    meta = old.meta // {
      description = "bemenu patched into the beamenu launcher's view layer";
      mainProgram = "bemenu";
    };
  });

  # beamenu — the launcher itself: links beamenu-view's libbemenu, owns the
  # event loop, and implements the provider set (apps, system, calculator,
  # emoji, clipboard, snippets, quicklinks, windows, files, script commands).
  # nix/home/beamenu.nix wraps the store path and wires the keybinds.
  beamenu = pkgs.rustPlatform.buildRustPackage {
    pname = "beamenu";
    version = "0.1.0";
    src = ../rust/beamenu;
    cargoLock.lockFile = ../rust/beamenu/Cargo.lock;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.beamenu-view ];
    meta.mainProgram = "beamenu";
  };

  # beamenu-calc — the scientific calculator plugin's worker.
  #
  # This is what exercises the plugin system end to end: a manifest with a
  # `view` command and `ui: "rpc"`, spawned through beamenu-canvas, talking
  # newline-delimited JSON-RPC over stdio. The launcher's built-in `=` provider
  # stays as it is; that one answers inline as you type, which the plugin
  # protocol cannot do, since the only message the canvas sends back is
  # form.submit.
  #
  # No GTK or pkg-config here: the worker never draws anything itself, it only
  # writes component trees for the canvas to render.
  beamenu-calc = pkgs.rustPlatform.buildRustPackage {
    pname = "beamenu-calc";
    version = "0.1.0";
    src = ../rust/beamenu-calc;
    cargoLock.lockFile = ../rust/beamenu-calc/Cargo.lock;
    meta.mainProgram = "beamenu-calc";
  };

  # beamenu-canvas — the WebKitGTK sidecar beamenu spawns for a plugin's
  # `view` command: a layer-shell window that renders the command's output
  # (streamed log text, or a JSON-RPC-driven component tree) under one
  # host-enforced design system. Workers never supply CSS or HTML, only
  # typed component trees; see rust/beamenu-canvas for the protocol.
  beamenu-canvas = pkgs.rustPlatform.buildRustPackage {
    pname = "beamenu-canvas";
    version = "0.1.0";
    src = ../rust/beamenu-canvas;
    cargoLock.lockFile = ../rust/beamenu-canvas/Cargo.lock;
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.wrapGAppsHook4
    ];
    buildInputs = [
      pkgs.gtk4
      pkgs.webkitgtk_6_0
      pkgs.gtk4-layer-shell
    ];
    meta.mainProgram = "beamenu-canvas";
  };

  # Claude Desktop for Linux (beta) — repackaged from Anthropic's .deb, which
  # is the only distribution channel upstream offers. See nix/claude-desktop.nix.
  claude-desktop = pkgsClaude.callPackage ../nix/claude-desktop.nix { };
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
