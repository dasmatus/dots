# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# Claude Desktop, the shell's QML tree and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  pkgsClaude,
  inputs,
  ...
}:
self: {
  # The home-manager CLI, taken from THIS flake's home-manager input rather
  # than from nixpkgs. `nix run .#home-switch` (flake/apps.nix) drives it to
  # apply homeConfigurations on a non-NixOS host, where there is usually no
  # `home-manager` on PATH at all — and where a nixpkgs-provided one could be
  # a different version than the config in flake/home.nix was evaluated
  # against, which is exactly the mismatch that produces activation errors
  # about unknown options.
  hm-cli = inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.home-manager;
  # Claude Desktop for Linux (beta) — repackaged from Anthropic's .deb, which
  # is the only distribution channel upstream offers. See nix/packages/claude-desktop.nix.
  claude-desktop = pkgsClaude.callPackage ../nix/packages/claude-desktop.nix { };
  # Betterbird, a Thunderbird fork, for its StatusNotifierItem tray icon.
  # nixpkgs dropped its own betterbird for want of a maintainer, but upstream
  # still ships a linux-x86_64 release tarball every ESR cycle, so this
  # repackages that the way nixpkgs' own thunderbird-bin repackages Mozilla's.
  # See nix/packages/betterbird.nix.
  betterbird = pkgs.callPackage ../nix/packages/betterbird.nix { };

  # ChromaLeon, the wallpaper-accent GNOME Shell extension. Built here rather
  # than taken from pkgs.gnomeExtensions because that generator fetches a
  # prebuilt e.g.o zip with no rev or patch seam, and this one carries a patch.
  # See nix/packages/chromaleon.nix.
  chromaleon = pkgs.callPackage ../nix/packages/chromaleon.nix { };
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
  # dots-sandbox — the per-app sandbox's policy model and pure
  # systemd-nspawn/-vmspawn argv translation (rust/dots-sandbox, a parallel
  # agent's work this task only wires into the flake: no app is wrapped by
  # it yet). `nix build .#dots-sandbox` is what the sandbox-policy-eval
  # check below shells out to for `policy validate`, and it is also the
  # binary the QML Settings page will eventually call `policy dump`
  # through.
  #
  # doCheck stays false. `src` here is only rust/dots-sandbox, so
  # tests/defaults_roundtrip.rs's read of
  # `../../nix/data/sandbox-policy.json` never finds the real file inside
  # the build sandbox and only ever exercises its own "skip cleanly"
  # branch — a green tick that never actually parsed the checked-in policy.
  # That alone would be a reason to distrust `doCheck = true` here even
  # though it would not fail outright. The harder, permanent reason is
  # forward-looking: this crate's own lib.rs doc comment is explicit that
  # spawning a real `systemd-nspawn`/`systemd-vmspawn` process is
  # deliberately left to a later task, and the tests that will matter once
  # that lands exercise real Linux namespaces, which the Nix build sandbox
  # refuses outright — so, same as every other crate whose real test run
  # cannot happen inside the build sandbox, that run moves out of the
  # package build and into `nix run .#nix-lint`, which is where this
  # crate's `cargo fmt --check && cargo clippy --all-targets -- -D
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

  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;

  # Exposed so `nix run .#nix-lint` can force the primer generator to run and
  # trip its build-time asserts, not because anyone installs this directly.
  # See nix/packages/dots-skills.nix.
  dots-skills-primer = (pkgs.callPackage ../nix/packages/dots-skills.nix { }).primer;
}
