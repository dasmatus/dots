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
  beamenu-view = pkgs.bemenu.overrideAttrs (old: {
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
    # Widened to rust/ (not the crate dir) so rust/palette.json — the single
    # source of truth for the system palette — lands in the store src too:
    # src/palette.rs pulls it in via include_str!("../../palette.json").
    src = pkgs.lib.fileset.toSource {
      root = ../rust;
      fileset = pkgs.lib.fileset.unions [
        ../rust/beamenu
        ../rust/palette.json
      ];
    };
    sourceRoot = "source/beamenu";
    cargoLock.lockFile = ../rust/beamenu/Cargo.lock;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.beamenu-view ];
    meta.mainProgram = "beamenu";
  };

  # beamenu-canvas — the WebKitGTK sidecar beamenu spawns for a plugin's
  # `view` command: a layer-shell window that renders the command's output
  # (streamed log text, or a JSON-RPC-driven component tree) under one
  # host-enforced design system. Workers never supply CSS or HTML, only
  # typed component trees; see rust/beamenu-canvas for the protocol.
  beamenu-canvas = pkgs.rustPlatform.buildRustPackage {
    pname = "beamenu-canvas";
    version = "0.1.0";
    # Same widening as beamenu above, and for the same reason: the canvas
    # sidecar's include_str!("../../palette.json") needs rust/palette.json
    # sitting next to the crate dir in the store src.
    src = pkgs.lib.fileset.toSource {
      root = ../rust;
      fileset = pkgs.lib.fileset.unions [
        ../rust/beamenu-canvas
        ../rust/palette.json
      ];
    };
    sourceRoot = "source/beamenu-canvas";
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
