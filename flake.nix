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
    # bun2nix vendors aipage's bun.lock JS deps (postcss/tailwind/autoprefixer)
    # for the in-flake aipage build (nix/aipage.nix). Overlay applied to a
    # dedicated pkgs instance (pkgsBun) so the system closure's pkgs stays
    # overlay-free.
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # AIPage (codeberg.org/dasmatus/aipage) is NOT a flake input: its built
    # dist-* dirs are gitignored in the sibling repo and its flake only exposes
    # an impure `apps.build`, so no flake input can reach a built artifact.
    # Instead nix/aipage.nix fetchGit-pins `main` at an eval-time FOD and builds
    # the dists inside this flake; nix/home/{brave,librewolf}.nix consume the
    # resulting packages.aipage-{chrome,firefox} (threaded via specialArgs).
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
      # nixpkgs with the bun2nix overlay, for the in-flake aipage build only.
      # Kept separate from `pkgs` so the bun2nix overlay doesn't leak into the
      # system closure (aipage's dists are static files — no runtime deps).
      pkgsBun = import nixpkgs {
        inherit system;
        overlays = [ inputs.bun2nix.overlays.default ];
      };
      aipagePackages = pkgsBun.callPackage ./nix/aipage.nix {
        rustPlatform = pkgsBun.rustPlatform;
      };
      # defaults.nix holds the non-install-time params (timezone, locale,
      # desktop, boot knobs, network backend); the installer TUI rewrites only
      # the four install answers (username/hostname/disk/swapSize) into
      # settings.nix on the target, so it is merged *under* settings.nix to
      # survive an install. See nix/defaults.nix.
      settings = (import ./nix/defaults.nix) // (import ./nix/settings.nix);

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
            ./nix/modules/network.nix
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
              isoImage.storeContents =
                [
                  self.packages.${system}.aipage-firefox
                  self.packages.${system}.aipage-chrome
                ]
                ++ nixpkgs.lib.optionals embedSystem [
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
          specialArgs = {
            inherit inputs settings;
            aipageFirefox = self.packages.${system}.aipage-firefox;
            aipageChrome = self.packages.${system}.aipage-chrome;
          };
          modules = [
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            lanzaboote.nixosModules.lanzaboote
            (import ./nix/disko.nix { inherit (settings) disks swapSize; })
            ./nix/modules/core.nix
            ./nix/modules/boot.nix
            ./nix/modules/network.nix
            ./nix/modules/searxng.nix
            ./nix/modules/virtualisation.nix
            ./nix/modules/users.nix
            ./nix/modules/hardening.nix
            ./nix/modules/maintenance.nix
            ./nix/modules/secureboot.nix
            ./nix/modules/desktop.nix
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
        # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned
        # fetchGit source — see nix/aipage.nix. Consumed by the LibreWolf and
        # Brave home modules via specialArgs, and embedded in both ISOs so the
        # installer substitutes them from the ISO store (offline-capable).
        aipage-firefox = aipagePackages.firefox;
        aipage-chrome = aipagePackages.chrome;
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

      # Dev shell for hacking on the two Rust crates (installer-tui and
      # wallpaper-tui): a plain Rust toolchain so `cargo fmt`/`cargo clippy`/
      # `cargo test`/`cargo run` work locally without a system rust install.
      # Both are pure TUIs with no native deps, so no pkg-config / webkit /
      # gtk stack is needed here (the old Tauri dev shell carried it).
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
          pkgs.rustfmt
          pkgs.clippy
        ];
        RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
      };

      checks.${system} = {
        dots-installer = self.packages.${system}.dots-installer;
        settings-eval = pkgs.writeText "settings-ok" (
          builtins.concatStringsSep "\n" [
            settings.username
            settings.hostname
            (builtins.concatStringsSep "," settings.disks)
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
        # Asserts the FIDO2 2FA tightening lands in the generated PAM rules
        # for hyprlock/ly/login: u2f required + unix required + deny disabled,
        # u2f rendered before unix. The dormant sudo service is intentionally
        # untouched (unix still "sufficient", deny still present); the global
        # u2f.control=required does flow into sudo's u2f rule, but sudo-rs
        # NOPASSWD skips PAM auth entirely. Catches a future nixpkgs bump that
        # silently changes the auto-rule controls/order or the deny
        # terminator. Eval-only (no build); reads the already-evaluated
        # tokyonight config (the tightening is in the module, requireKey=true
        # by default).
        fido-2fa-eval =
          let
            cfg = self.nixosConfigurations.tokyonight.config;
            svc = cfg.security.pam.services;
            need = [
              "hyprlock"
              "ly"
              "login"
            ];
            twoFa =
              s:
              let
                r = svc.${s}.rules.auth;
              in
              r.u2f.control == "required"
              && r.unix.control == "required"
              && !r.deny.enable
              && r.u2f.order < r.unix.order;
          in
          assert builtins.all twoFa need;
          assert cfg.security.pam.u2f.control == "required";
          assert svc.sudo.rules.auth.unix.control == "sufficient";
          assert svc.sudo.rules.auth.deny.enable;
          pkgs.writeText "fido-2fa-ok" "required+required";
        # Asserts the in-flake aipage build (nix/aipage.nix) evaluates, the
        # manifest is parseable at eval time (pure-eval readFile of a fetchGit
        # store path), the gecko addon id is stable, and both targets are MV2.
        # Eval-only — does not build the wasm (too slow for the lint gate); a
        # full `nix build .#aipage-firefox .#aipage-chrome` is the build gate.
        aipage-eval =
          let
            ff = self.packages.${system}.aipage-firefox;
            ch = self.packages.${system}.aipage-chrome;
            ffMan = ff.passthru.manifest;
            chMan = ch.passthru.manifest;
          in
          assert ffMan.browser_specific_settings.gecko.id == "edupage-ai-sidebar@hesburger.dev";
          assert ffMan.manifest_version == 2;
          assert chMan.manifest_version == 2;
          assert ff.passthru.aipageVersion == ffMan.version;
          pkgs.writeText "aipage-eval-ok" ff.passthru.aipageVersion;
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
