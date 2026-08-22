# Shared let-bindings for the flake outputs — the bits every output file
# needs (pkgs, settings, the bun2nix-overlaid pkgsBun for aipage, and the
# mkIso helper that builds the LiveISO closures).
#
# `inputs` here is the flake's full inputs attrset (with `self` injected by the
# outputs function); we hand the subset each consumer needs down the line.
{ inputs, nixpkgs, ... }:
let
  system = "x86_64-linux";
  pkgs = nixpkgs.legacyPackages.${system};
  # nixpkgs with the bun2nix overlay, for the in-flake aipage build only.
  # Kept separate from `pkgs` so the bun2nix overlay doesn't leak into the
  # system closure (aipage's dists are static files — no runtime deps).
  pkgsBun = import nixpkgs {
    inherit system;
    overlays = [ inputs.bun2nix.overlays.default ];
  };
  aipagePackages = pkgsBun.callPackage ../nix/aipage.nix {
    rustPlatform = pkgsBun.rustPlatform;
  };
  # nixpkgs that permits exactly one unfree package, for the Claude desktop
  # app. nix/modules/core.nix's allowUnfreePredicate governs the NixOS `pkgs`
  # only; `packages.${system}` is built from the plain legacyPackages above,
  # which has no config, so `nix build .#claude-desktop` would be refused
  # without this. Kept separate from `pkgs` for the same reason pkgsBun is:
  # so the permission does not leak into the rest of the closure.
  pkgsClaude = import nixpkgs {
    inherit system;
    config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-desktop";
  };
  # defaults.nix holds the non-install-time params (timezone, locale, desktop,
  # boot knobs, network backend); the installer TUI rewrites only the four
  # install answers (username/hostname/disk/swapSize) into settings.nix on the
  # target, so it is merged *under* settings.nix to survive an install.
  # See nix/defaults.nix.
  settings = (import ../nix/defaults.nix) // (import ../nix/settings.nix);

  mkIso =
    embedSystem:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs settings;
        dotsSelf = inputs.self;
      };
      modules = [
        ../nix/iso.nix
        ../nix/modules/network.nix
        {
          # System closures alone don't make nixos-install offline-capable:
          # evaluating the flake also needs the locked input sources.
          # The embedded closure is built against the committed facter.json
          # stub; the installer regenerates the report on real hardware, so
          # the delta (drivers, microcode) still comes from the binary cache.
          #
          # The aipage dists and the beamenu launcher are embedded on BOTH
          # ISOs (not gated on embedSystem): they're small static store
          # paths, and embedding them lets the installer substitute them
          # from the ISO store instead of rebuilding Rust/WASM/JS/C at
          # install time, which keeps lean-ISO installs offline-capable for
          # them. beamenu-view is listed alongside the binary because it is
          # a runtime dependency, not just a build one — beamenu dlopens its
          # renderers out of that store path.
          isoImage.storeContents = [
            inputs.self.packages.${system}.aipage-firefox
            inputs.self.packages.${system}.aipage-chrome
            inputs.self.packages.${system}.beamenu
            inputs.self.packages.${system}.beamenu-view
          ]
          ++ nixpkgs.lib.optionals embedSystem [
            inputs.self.nixosConfigurations.tokyonight.config.system.build.toplevel
            nixpkgs.outPath
            inputs.home-manager.outPath
            inputs.disko.outPath
          ];
        }
      ];
    };
in
{
  inherit
    system
    pkgs
    pkgsBun
    pkgsClaude
    aipagePackages
    settings
    mkIso
    ;
}
