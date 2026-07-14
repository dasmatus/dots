{
  description = "tokyonight-dots — NixOS system + home-manager dotfiles + LiveISO installer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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

  outputs = inputs@{ self, nixpkgs, home-manager, disko, lanzaboote }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      settings = import ./nix/settings.nix;

      mkHost = variant: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs settings variant; };
        modules = [
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
    in
    {
      nixosConfigurations = {
        tokyonight-intel = mkHost "intel";
        tokyonight-amd = mkHost "amd";
      };

      packages.${system} = {
        dots-installer = pkgs.rustPlatform.buildRustPackage {
          pname = "dots-installer";
          version = "0.1.0";
          src = ./installer-tui;
          cargoLock.lockFile = ./installer-tui/Cargo.lock;
        };
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;

      checks.${system} = {
        dots-installer = self.packages.${system}.dots-installer;
        settings-eval = pkgs.writeText "settings-ok"
          (builtins.concatStringsSep "\n" [ settings.username settings.hostname settings.disk settings.swapSize ]);
      };
    };
}
