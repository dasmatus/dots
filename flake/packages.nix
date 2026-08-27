# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# Claude Desktop, the shell's QML tree and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  pkgsClaude,
  ...
}:
self: {
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
    # The launcher entry's icon (nix/home/wallpaper-tui.nix names it
    # `wallpaper-tui`, unqualified). It ships here rather than as a home file
    # because the launcher resolves an `Icon=` name through the icon themes on
    # XDG_DATA_DIRS, and hicolor in the profile is what puts it there — the
    # same lookup the GNOME app grid makes.
    postInstall = ''
      install -Dm444 ${../rust/wallpaper-tui/wallpaper-tui.svg} \
        "$out/share/icons/hicolor/scalable/apps/wallpaper-tui.svg"
    '';
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
    # See wallpaper-tui above for why the icon ships with the package. Named
    # as a Nix path rather than a relative one: cargoInstallHook does not run
    # with the unpacked source as its cwd.
    postInstall = ''
      install -Dm444 ${../rust/hyprmon/hyprmon.svg} \
        "$out/share/icons/hicolor/scalable/apps/hyprmon.svg"
    '';
    meta.mainProgram = "hyprmon";
  };
  # dots-memory-mcp — the stateless stdio MCP server over the agentmem
  # Postgres schema (plans 0-2). Built at the flake level for the same
  # reasons as hyprmon; `rmcp` has no nixpkgs package, so it is vendored
  # straight through Cargo.lock like every other crate here.
  dots-memory-mcp = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-memory-mcp";
    version = "0.1.0";
    src = ../rust/dots-memory-mcp;
    cargoLock.lockFile = ../rust/dots-memory-mcp/Cargo.lock;
    meta.mainProgram = "dots-memory-mcp";
  };
  # dots-memory-derive — plan 5's mechanical extractor: walks the checkout
  # (the flake/nixos.nix modules list, the nix/home/default.nix imports,
  # dots.* declaration-to-use pairs, the flake/apps.nix names) and prints
  # `origin = 'derived'` Mermaid edges for `nix run .#memory-derive` to feed
  # into `agentmem.rebuild_derived`. No Postgres headers needed, unlike
  # pg-agentmem above — plain rustPlatform.buildRustPackage is enough.
  #
  # doCheck stays false: tests/derive_emit.rs deliberately runs the
  # extractor against this checkout's own tree (flake/nixos.nix and
  # friends), which is exactly what plan 5 task 2 asks it to assert
  # against. `src` above is only rust/dots-memory-derive, so inside the
  # build sandbox those repo-root files never exist and every test fails
  # on a bare "No such file or directory" — not a real regression. The
  # suite still runs correctly outside the sandbox: `nix run .#nix-lint`
  # (and plain `cargo test` from a checkout) exercises it against the
  # real tree.
  dots-memory-derive = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-memory-derive";
    version = "0.1.0";
    src = ../rust/dots-memory-derive;
    cargoLock.lockFile = ../rust/dots-memory-derive/Cargo.lock;
    doCheck = false;
    meta.mainProgram = "dots-memory-derive";
  };
  # quickshell-config — the shell's QML tree with Palette.qml generated from
  # rust/palette.json. nix/home/quickshell/default.nix builds the same thing
  # with the real state directory; this one exists so `nix run .#nix-lint` has
  # something to point qmllint at, and so a broken palette fails the flake
  # rather than the next login. The stateHome here only reaches a FileView
  # path string, so a placeholder is enough to lint against.
  quickshell-config = import ../nix/home/quickshell/tree.nix {
    inherit pkgs;
    stateHome = "/var/empty/.local/state";
    # The real cheatsheet, not an empty stub: linting a tree whose data files
    # are all empty would not exercise the delegates that read them.
    keybinds = import ../nix/home/keybinds.nix;
  };

  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/aipage.nix. Consumed by the LibreWolf and Brave home
  # modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;

  # pg_agentmem — the pgrx extension backing the Postgres memory plugin
  # (docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md):
  # content addressing, id slugification, and a strict-subset Mermaid
  # flowchart parser/renderer, all IMMUTABLE, all in schema `agentmem`.
  # Pinned to postgresql_18 and cargo-pgrx 0.18.1 to match `pgrx = "=0.18.1"`
  # in Cargo.toml — an unpinned pair silently rebuilds bindgen output against
  # the wrong server headers.
  #
  # doCheck stays false, matching every other pgrx extension already in this
  # nixpkgs revision (pg_graphql, pgx_ulid, pg_search, timescaledb_toolkit,
  # pglite_fusion, pgvectorscale — all `doCheck = false`, pgx_ulid.nix says so
  # in so many words: "pgrx tests try to install the extension into
  # postgresql nix store"). Verified here directly: `cargo pgrx test`
  # reinstalls the compiled .so and .control file at the exact path
  # `postgresql.pg_config --sharedir`/`--pkglibdir` report, which for a
  # nixpkgs-built `postgresql_18` is the package's own immutable store
  # output, so the reinstall dies with `Permission denied (os error 13)`
  # before a single #[pg_test] assertion runs — every one of the crate's 16
  # tests failed on that same write, not on their own logic. The tests
  # still exist (rust/pg-agentmem/tests/) and still run correctly, verified
  # by pointing a throwaway `cargo-pgrx pgrx init` at a writable copy of the
  # postgresql_18 output outside the Nix sandbox.
  pg-agentmem = pkgs.buildPgrxExtension {
    pname = "pg_agentmem";
    version = "0.1.0";
    src = ../rust/pg-agentmem;
    postgresql = pkgs.postgresql_18;
    cargo-pgrx = pkgs.cargo-pgrx;
    cargoLock.lockFile = ../rust/pg-agentmem/Cargo.lock;
    doCheck = false;
  };

  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;
}
