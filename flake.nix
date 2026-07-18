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

    # Encrypted repo secrets (nix/modules/secrets.nix); darwin cut — this
    # flake is x86_64-linux only and the follows keeps nix-darwin out of
    # the lock file.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.darwin.follows = "";
    };
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
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      settings = import ./nix/settings.nix;

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
            dotsSelf = self;
          };
          modules = [
            ./nix/iso.nix
            {
              # System closures alone don't make nixos-install offline-capable:
              # evaluating the flake also needs the locked input sources.
              # The embedded closure is built against the committed facter.json
              # stub; the installer regenerates the report on real hardware, so
              # the delta (drivers, microcode) still comes from the binary cache.
              isoImage.storeContents = nixpkgs.lib.optionals embedSystem [
                self.nixosConfigurations.tokyonight.config.system.build.toplevel
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
        # Hardware is not baked into variants anymore: nix/hosts.nix reads the
        # nixos-facter report the installer generates on the target.
        tokyonight = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs settings; };
          modules = [
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            lanzaboote.nixosModules.lanzaboote
            inputs.agenix.nixosModules.default
            (import ./nix/disko.nix { inherit (settings) disk swapSize; })
            ./nix/modules/core.nix
            ./nix/modules/boot.nix
            ./nix/modules/network.nix
            ./nix/modules/desktop.nix
            ./nix/modules/searxng.nix
            ./nix/modules/virtualisation.nix
            ./nix/modules/users.nix
            ./nix/modules/hardening.nix
            ./nix/modules/maintenance.nix
            ./nix/modules/secrets.nix
            ./nix/modules/secureboot.nix
            ./nix/hosts.nix
          ];
        };
        # Lean by default: the flake rides on the ISO, packages come from the
        # binary cache during install. live-iso-full embeds the prebuilt
        # system closure for offline installs (much bigger image).
        live-iso = mkIso false;
        live-iso-full = mkIso true;
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
        # Microsoft-signed Fedora shim for the Secure Boot ISO chain.
        shim-signed = pkgs.callPackage ./nix/shim-signed.nix { };
        # Toolbelt for scripts/sign-iso.sh + the Secure Boot smoke test
        # (the script `nix shell`s this when the tools aren't on PATH).
        sb-tools = pkgs.buildEnv {
          name = "sb-tools";
          paths = sbToolPackages;
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

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
        # The committed facter.json stub ({}) must leave every detection off,
        # including the nvidia if-then-else in nix/hosts.nix.
        facter-stub-eval =
          assert
            self.nixosConfigurations.tokyonight.config.services.xserver.videoDrivers == [
              "modesetting"
            ];
          pkgs.writeText "facter-stub-ok" "modesetting";
        # A synthetic report with an NVIDIA card (PCI vendor 0x10de = 4318)
        # must flip videoDrivers to nvidia, engage facter's CPU detection, and
        # pass every module assertion — asserting on config.assertions forces
        # the nvidia package eval, so a broken unfree allowlist fails here
        # instead of on the first on-machine rebuild. The cpu entry is
        # mandatory: facter asserts a non-empty hardware.cpu on baremetal.
        facter-nvidia-eval =
          let
            nvidiaSystem = self.nixosConfigurations.tokyonight.extendModules {
              modules = [
                {
                  hardware.facter.report = {
                    version = 2;
                    system = "x86_64-linux";
                    virtualisation = "none";
                    hardware = {
                      cpu = [ { vendor_name = "AuthenticAMD"; } ];
                      graphics_card = [
                        {
                          vendor = {
                            hex = "10de";
                            value = 4318;
                          };
                        }
                      ];
                    };
                  };
                }
              ];
            };
            inherit (nvidiaSystem) config;
            failed = map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
          in
          assert config.services.xserver.videoDrivers == [ "nvidia" ];
          assert config.hardware.nvidia.open;
          assert config.hardware.cpu.amd.updateMicrocode;
          assert builtins.elem "amd_pstate=active" config.boot.kernelParams;
          assert failed == [ ];
          pkgs.writeText "facter-nvidia-ok" "nvidia";
      }
      # LiveISO boot oracles (NixOS test framework) — see tests/README.md.
      // import ./tests {
        inherit pkgs sbToolPackages;
        inherit (pkgs) lib;
        inherit (self.packages.${system}) iso shim-signed;
        signScript = ./scripts/sign-iso.sh;
      };
    };
}
