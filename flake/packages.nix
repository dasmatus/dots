# packages.${system} — the dots-installer Rust TUI, the settings menu, the
# shell's QML tree, the in-flake aipage dists, the release proxy and the two
# LiveISO images.
{
  pkgs,
  aipagePackages,
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
  dots-installer = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-installer";
    version = "0.1.0";
    src = ../rust/installer-tui;
    cargoLock.lockFile = ../rust/installer-tui/Cargo.lock;
  };
  # Betterbird, a Thunderbird fork, for its StatusNotifierItem tray icon.
  # nixpkgs dropped its own betterbird for want of a maintainer, but upstream
  # still ships a linux-x86_64 release tarball every ESR cycle, so this
  # repackages that the way nixpkgs' own thunderbird-bin repackages Mozilla's.
  # See nix/packages/betterbird.nix.
  betterbird = pkgs.callPackage ../nix/packages/betterbird.nix { };
  settings = pkgs.rustPlatform.buildRustPackage {
    pname = "settings";
    version = "0.1.0";
    src = ../rust/settings-global;
    cargoLock.lockFile = ../rust/settings-global/Cargo.lock;
    # The crate is named global-settings, so `nix run .#settings` needs the
    # binary spelled out.
    meta.mainProgram = "global-settings";
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

  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;

  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/packages/aipage.nix. Consumed by the LibreWolf and Brave
  # home modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;

  # The loopback server nix/modules/system/sysupdate.nix starts while
  # systemd-sysupdate fetches the weekly full LiveISO, which GitHub only
  # holds in parts (rust/dots-release-proxy/src/lib.rs).
  dots-release-proxy = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-release-proxy";
    version = "0.1.0";
    src = ../rust/dots-release-proxy;
    cargoLock.lockFile = ../rust/dots-release-proxy/Cargo.lock;
    # Tested in the cargo lanes (.github/workflows/ci.yml), like the rest.
    doCheck = false;
    meta.mainProgram = "dots-release-proxy";
  };
}
