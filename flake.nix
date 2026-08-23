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
    # (userborn creds) and Wi-Fi profiles survive the root being wiped each
    # boot.
    impermanence = {
      url = "github:nix-community/impermanence";
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
    # Hyprland is NOT a flake input: the system compositor comes from nixpkgs
    # (programs.hyprland in nix/modules/desktop.nix uses the module's default
    # `package = pkgs.hyprland`). nixpkgs' Hyprland is built by Hydra and lives
    # on cache.nixos.org (indefinite retention), so the prebuilt is always
    # substituted. A pinned Hyprland flake input was tried instead (for
    # independent version pinning) but its only prebuilt source —
    # hyprland.cachix.org — evicts old tagged builds (Hyprland's CI rebuilds
    # main with bumped inputs on every push, so a release tag ages out ~months
    # after release; v0.55.0's prebuilt was gone), and `inputs.nixpkgs.follows`
    # on that input additionally defeated the cache by changing input hashes.
    # Net: the flake-input route built the compositor from source on every
    # rebuild. See nix/modules/desktop.nix for the full rationale.
    # AIPage (codeberg.org/dasmatus/aipage) is NOT a flake input: its built
    # dist-* dirs are gitignored in the sibling repo and its flake only
    # exposes an impure `apps.build`, so no flake input can reach a built
    # artifact. Instead nix/aipage.nix fetchgit-pins `main` at a hash-
    # determined fixed-output derivation and builds the dists inside this
    # flake; nix/home/{brave,librewolf}.nix consume the resulting
    # packages.aipage-{chrome,firefox} (threaded via specialArgs). A
    # derivation (not the builtins.fetchGit primitive) so its output path is
    # hash-determined — offline `nixos-install --flake` can substitute it
    # without the fetcher cache or git.
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      disko,
      nixvim,
      haumea,
      # firefox-addons rides along inside `inputs` (specialArgs)
      ...
    }:
    let
      # Shared let-bindings (pkgs, settings, the bun2nix-overlaid pkgsBun for
      # aipage, and the mkIso helper) live in flake/lib.nix so every output
      # file shares one source of truth.
      lib = import ./flake/lib.nix { inherit inputs nixpkgs; };
      # NB no `self` here: lib.nix does not export it, and inheriting it
      # would shadow the real outputs-arg `self` above with a missing attr —
      # a lazy landmine that only detonated when packages.iso forced it.
      inherit (lib)
        system
        pkgs
        pkgsClaude
        aipagePackages
        settings
        mkIso
        ;
      # nixosConfigurations split into flake/nixos.nix (the installed system
      # + the two LiveISO closures). nixosConfigs also exports mkTokyonight
      # (a settings-parameterized builder) for tests/default.nix — it is NOT a
      # nixosConfiguration, so strip it before exposing nixosConfigurations.
      nixosConfigs = import ./flake/nixos.nix {
        inherit
          self
          inputs
          nixpkgs
          settings
          mkIso
          ;
      };
    in
    {
      nixosConfigurations = builtins.removeAttrs nixosConfigs [ "mkTokyonight" ];

      # packages.${system} split into flake/packages.nix; it receives `self`
      # (this outputs attrset) so iso/iso-full can reach the LiveISO closures
      # built above.
      packages.${system} = import ./flake/packages.nix {
        inherit pkgs aipagePackages pkgsClaude;
      } self;

      # Task-runner apps — the retired Justfile, now nix-native. See
      # flake/apps.nix.
      apps.${system} = import ./flake/apps.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
      } self;

      formatter.${system} = pkgs.nixfmt-tree;

      # Rust dev shell
      devShells.${system} = import ./flake/devshell.nix {
        inherit pkgs;
      };

      # The cheap eval-only checks (settings, facter, fido-2fa, aipage) +
      # the dots-installer build gate — see flake/checks.nix.
      checks.${system} =
        (import ./flake/checks.nix {
          inherit pkgs system;
        } self)
        # LiveISO boot oracle (NixOS test framework) — see tests/README.md.
        # mkTokyonight + dotsFlake + inputs feed the limine-install-boot test
        # (pre-build a test-settings closure; stage the flake in the installer VM).
        // import ./tests {
          inherit pkgs inputs;
          inherit (pkgs) lib;
          inherit (self.packages.${system}) iso;
          inherit (nixosConfigs) mkTokyonight;
          dotsFlake = self;
        };
    };
}
