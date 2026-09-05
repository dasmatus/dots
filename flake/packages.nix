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
  # is the only distribution channel upstream offers. See nix/packages/claude-desktop.nix.
  claude-desktop = pkgsClaude.callPackage ../nix/packages/claude-desktop.nix { };
  # Betterbird, a Thunderbird fork, for its StatusNotifierItem tray icon.
  # nixpkgs dropped its own betterbird for want of a maintainer, but upstream
  # still ships a linux-x86_64 release tarball every ESR cycle, so this
  # repackages that the way nixpkgs' own thunderbird-bin repackages Mozilla's.
  # See nix/packages/betterbird.nix.
  betterbird = pkgs.callPackage ../nix/packages/betterbird.nix { };
  dots-installer = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-installer";
    version = "0.1.0";
    src = ../rust/installer-tui;
    cargoLock.lockFile = ../rust/installer-tui/Cargo.lock;
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
  # dots-memory-mcp — the stateless stdio MCP server over the agentmem
  # Postgres schema (plans 0-2). Built at the flake level for the same
  # reasons as the other crates here — a shared cache key and a working
  # `nix build .#dots-memory-mcp`; `rmcp` has no nixpkgs package, so it is
  # vendored straight through Cargo.lock like every other crate here.
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
  # dots-sandbox — the per-app sandbox's policy model and pure
  # systemd-nspawn/-vmspawn argv translation (rust/dots-sandbox, a parallel
  # agent's work this task only wires into the flake: no app is wrapped by
  # it yet). `nix build .#dots-sandbox` is what the sandbox-policy-eval
  # check below shells out to for `policy validate`, and it is also the
  # binary the QML Settings page will eventually call `policy dump`
  # through.
  #
  # doCheck stays false, for a reason with the same shape as
  # dots-memory-derive above rather than the same cause: `src` here is only
  # rust/dots-sandbox, so tests/defaults_roundtrip.rs's read of
  # `../../nix/data/sandbox-policy.json` never finds the real file inside
  # the build sandbox and only ever exercises its own "skip cleanly"
  # branch — a green tick that never actually parsed the checked-in policy.
  # That alone would be a reason to distrust `doCheck = true` here even
  # though it would not fail outright. The harder, permanent reason is
  # forward-looking: this crate's own lib.rs doc comment is explicit that
  # spawning a real `systemd-nspawn`/`systemd-vmspawn` process is
  # deliberately left to a later task, and the tests that will matter once
  # that lands exercise real Linux namespaces, which the Nix build sandbox
  # refuses outright — the identical restriction pg_agentmem and
  # dots-memory-derive already route around by moving their real test run
  # out of the package build and into `nix run .#nix-lint`, which is where
  # this crate's `cargo fmt --check && cargo clippy --all-targets -- -D
  # warnings && cargo test` line now runs too.
  dots-sandbox = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-sandbox";
    version = "0.1.0";
    src = ../rust/dots-sandbox;
    cargoLock.lockFile = ../rust/dots-sandbox/Cargo.lock;
    doCheck = false;
    meta.mainProgram = "dots-sandbox";
  };
  # quickshell-config — the shell's QML tree with Palette.qml generated from
  # nix/data/palette.json. nix/home/desktop/quickshell/default.nix builds the same thing
  # with the real state directory; this one exists so `nix run .#nix-lint` has
  # something to point qmllint at, and so a broken palette fails the flake
  # rather than the next login. The stateHome here only reaches a FileView
  # path string, so a placeholder is enough to lint against.
  quickshell-config = import ../nix/home/desktop/quickshell/tree.nix {
    inherit pkgs;
    stateHome = "/var/empty/.local/state";
    cacheHome = "/var/empty/.cache";
    # The real cheatsheet, not an empty stub: linting a tree whose data files
    # are all empty would not exercise the delegates that read them.
    keybinds = import ../nix/home/desktop/keybinds.nix;
  };

  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/packages/aipage.nix. Consumed by the LibreWolf and Brave home
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

  # Exposed so `nix run .#nix-lint` can force the primer generator to run and
  # trip its build-time asserts, not because anyone installs this directly.
  # See nix/packages/dots-skills.nix.
  dots-skills-primer = (pkgs.callPackage ../nix/packages/dots-skills.nix { }).primer;
}
