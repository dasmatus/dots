# Shared let-bindings for the flake outputs — the bits every output file
# needs (pkgs, settings, the bun2nix-overlaid pkgsBun for aipage, the sb-tools
# package list, and the mkIso helper that builds the LiveISO closures).
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
  # defaults.nix holds the non-install-time params (timezone, locale, desktop,
  # boot knobs, network backend); the installer TUI rewrites only the four
  # install answers (username/hostname/disk/swapSize) into settings.nix on the
  # target, so it is merged *under* settings.nix to survive an install.
  # See nix/defaults.nix.
  settings = (import ../nix/defaults.nix) // (import ../nix/settings.nix);

  # Everything scripts/sign-iso.sh needs: shared by the sb-tools buildEnv
  # (host-side signing) and the in-sandbox signing fixture in tests/.
  sbToolPackages = with pkgs; [
    sbsigntool
    openssl
    binutils
    mtools
    dosfstools
    xorriso
    python3Packages.virt-firmware
  ];

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
            inputs.lanzaboote.outPath
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
    settings
    sbToolPackages
    mkIso
    ;
}
