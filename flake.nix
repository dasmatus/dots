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

    # Ephemeral-root persistence (tmpfs `/` + bind-mounts from a persistent
    # /persist subvol). Wired in nix/modules/impermanence.nix so /var/lib/nixos
    # (userborn creds), /var/lib/sbctl (Secure Boot keys) and Wi-Fi profiles
    # survive the root being wiped each boot.
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    haumea = {
      url = "github:nix-community/haumea/v0.2.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # rycee's pre-packaged Firefox addons (Nix-pinned XPIs for the LibreWolf
    # profile in nix/home/librewolf.nix) — the subflake, not the whole NUR.
    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # bun2nix vendors aipage's bun.lock JS deps (postcss/tailwind/autoprefixer)
    # for the in-flake aipage build (nix/aipage.nix). Overlay applied to a
    # dedicated pkgs instance (pkgsBun) so the system closure's pkgs stays
    # overlay-free.
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Hyprland compositor is pinned to a release tag (consumed by
    # nix/modules/desktop.nix as packages.hyprland) so the system compositor
    # stays on a known-good version rather than tracking nixpkgs' rolling
    # bump — a surprise minor bump mid-session is more disruptive than a
    # deliberate `nix flake update` of this input.
    hyprland = {
      url = "github:hyprwm/Hyprland?ref=v0.55.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # AIPage (codeberg.org/dasmatus/aipage) is NOT a flake input: its built
    # dist-* dirs are gitignored in the sibling repo and its flake only
    # exposes an impure `apps.build`, so no flake input can reach a built
    # artifact. Instead nix/aipage.nix fetchGit-pins `main` at an eval-time
    # FOD and builds the dists inside this flake; nix/home/{brave,librewolf}
    # .nix consume the resulting packages.aipage-{chrome,firefox} (threaded
    # via specialArgs).
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      disko,
      lanzaboote,
      nixvim,
      haumea,
      # firefox-addons rides along inside `inputs` (specialArgs)
      ...
    }:
    let
      # Shared let-bindings (pkgs, settings, the bun2nix-overlaid pkgsBun for
      # aipage, the sb-tools package list, the mkIso helper) live in
      # flake/lib.nix so every output file shares one source of truth.
      lib = import ./flake/lib.nix { inherit inputs nixpkgs; };
      inherit (lib)
        system
        pkgs
        pkgsBun
        aipagePackages
        settings
        sbToolPackages
        mkIso
        ;
    in
    {
      # nixosConfigurations split into flake/nixos.nix (the installed system
      # + the two LiveISO closures).
      nixosConfigurations = import ./flake/nixos.nix {
        inherit
          inputs
          nixpkgs
          settings
          mkIso
          ;
      };

      # packages.${system} split into flake/packages.nix; it receives `self`
      # (this outputs attrset) so iso/iso-full can reach the LiveISO closures
      # built above.
      packages.${system} = import ./flake/packages.nix {
        inherit pkgs aipagePackages sbToolPackages;
      } self;

      # Task-runner apps — the retired Justfile, now nix-native. See
      # flake/apps.nix.
      apps.${system} = import ./flake/apps.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
      } self;

      formatter.${system} = pkgs.nixfmt-tree;

      # Dev shell for the two Rust crates — see flake/devshell.nix.
      devShells.${system} = import ./flake/devshell.nix { inherit pkgs; };

      # The cheap eval-only checks (settings, facter, fido-2fa, aipage) +
      # the dots-installer build gate — see flake/checks.nix.
      checks.${system} =
        (import ./flake/checks.nix {
          inherit pkgs system;
        } self)
        # LiveISO boot oracles (NixOS test framework) — see tests/README.md.
        // import ./tests {
          inherit pkgs sbToolPackages;
          inherit (pkgs) lib;
          inherit (self.packages.${system}) iso shim-signed;
          signScript = ./scripts/sign-iso.sh;
        };
    };
}
