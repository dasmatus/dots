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
    in
    {
      formatter.${system} = pkgs.nixfmt-rfc-style;

      checks.${system} = {
        settings-eval = pkgs.writeText "settings-ok"
          (builtins.concatStringsSep "\n" [ settings.username settings.hostname settings.disk settings.swapSize ]);
      };
    };
}
