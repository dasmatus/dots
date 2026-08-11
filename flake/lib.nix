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
  # Haskell packages for the abstracttui compat layer (haskell/abstracttui).
  # nixpkgs ships reflex-vty 0.6.2.1, which lacks Reflex.Vty.Canvas and
  # Reflex.Vty.Test.Snapshot — pin the maintained 1.2.0.0 from source instead.
  # The repo moved from obsidiansystems/reflex-vty to reflex-frp/reflex-vty
  # (the old owner 404s); fetchFromGitHub + callCabal2nix builds it under our
  # GHC so its transitive deps resolve here, once.
  haskellPackages = pkgs.haskellPackages.override {
    overrides = hpkgs: hprev: {
      reflex-vty = hpkgs.callCabal2nix "reflex-vty"
        (pkgs.fetchFromGitHub {
          owner = "reflex-frp";
          repo = "reflex-vty";
          rev = "refs/tags/v1.2.0.0";
          hash = "sha256-/q+qwLpLoPHklDM/ZeqbsATCRYgkhs7WxfXHLCTJkHE=";
        })
        { };
    };
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
          # The aipage dists are embedded on BOTH ISOs (not gated on
          # embedSystem): they're small static store paths, and embedding
          # them lets the installer substitute AIPage from the ISO store
          # instead of rebuilding Rust/WASM/JS at install time (and keeps
          # lean-ISO installs offline-capable for the extension itself).
          isoImage.storeContents = [
            inputs.self.packages.${system}.aipage-firefox
            inputs.self.packages.${system}.aipage-chrome
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
    aipagePackages
    haskellPackages
    settings
    mkIso
    ;
}
