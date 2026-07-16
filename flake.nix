{
  description = "tokyonight-dots — NixOS system + home-manager dotfiles + LiveISO installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flatpaks.url = "github:in-a-dil-emma/declarative-flatpak/latest";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      disko,
      lanzaboote,
      flatpaks,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      settings = import ./nix/settings.nix;

      mkHost =
        variant:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs settings variant; };
          modules = [
            flatpaks.nixosModules.default
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            lanzaboote.nixosModules.lanzaboote
            (import ./nix/disko.nix { inherit (settings) disk swapSize; })
            ./nix/modules/core.nix
            ./nix/modules/boot.nix
            ./nix/modules/network.nix
            ./nix/modules/desktop.nix
            ./nix/modules/virtualisation.nix
            ./nix/modules/users.nix
            ./nix/modules/hardening.nix
            ./nix/modules/maintenance.nix
            ./nix/modules/secureboot.nix
            ./nix/hosts/${variant}.nix
          ];
        };
      mkIso =
        variants:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit inputs settings;
            dotsSelf = self;
          };
          modules = [
            ./nix/iso.nix
            {
              # System closures alone don't make nixos-install offline-capable:
              # evaluating the flake also needs the locked input sources.
              isoImage.storeContents =
                map (v: self.nixosConfigurations."tokyonight-${v}".config.system.build.toplevel) variants
                ++ nixpkgs.lib.optionals (variants != [ ]) [
                  nixpkgs.outPath
                  home-manager.outPath
                  disko.outPath
                  lanzaboote.outPath
                ];
            }
          ];
        };
    in
    {
      nixosConfigurations = {
        tokyonight-intel = mkHost "intel";
        tokyonight-amd = mkHost "amd";
        # Lean by default: the flake rides on the ISO, packages come from the
        # binary cache during install. live-iso-full embeds both prebuilt
        # system closures for offline installs (much bigger image).
        live-iso = mkIso [ ];
        live-iso-full = mkIso [
          "intel"
          "amd"
        ];
      };

      packages.${system} = {
        dots-installer = pkgs.rustPlatform.buildRustPackage {
          pname = "dots-installer";
          version = "0.1.0";
          src = ./installer-tui;
          cargoLock.lockFile = ./installer-tui/Cargo.lock;
        };
        iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
        iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;

      checks.${system} = {
        dots-installer = self.packages.${system}.dots-installer;
        settings-eval = pkgs.writeText "settings-ok" (
          builtins.concatStringsSep "\n" [
            settings.username
            settings.hostname
            settings.disk
            settings.swapSize
          ]
        );
      };
    };
}
