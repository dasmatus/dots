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
    # /persist subvol). Wired in nix/modules/system/impermanence.nix so /var/lib/nixos
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

    # Declarative microVMs. The per-app sandbox uses these to confine a package
    # in a real hardware boundary rather than a namespace, which is what makes
    # "no app is unsandboxed" achievable: the exemptions the container design
    # needed (a terminal whose children inherit its confinement, a launcher
    # whose whole job is exec'ing browsers) stop being exemptions once each app
    # gets its own kernel.
    #
    # It also sidesteps the blocker that killed the nspawn route outright:
    # unprivileged managed-mode nspawn cannot start on a nixpkgs-built systemd,
    # because systemd-nsresourced wants a BPF-LSM program compiled out for want
    # of kernel BTF. A VM asks nsresourced for nothing.
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    haumea = {
      url = "github:nix-community/haumea/v0.2.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # age-encrypted secrets. Used for exactly one thing: the git identity
    # (secrets/git-identity.age, wired in nix/home/secrets/identity.nix). That
    # identity used to be a plaintext string in nix/data/settings.nix, which
    # put a real name and address in a public repo and in the world-readable
    # Nix store.
    #
    # agenix rather than sops-nix because the trust root is already here:
    # `dots-keys` (nix/home/apps/bitwarden.nix) exports the Bitwarden-vault SSH
    # key, age speaks ssh-ed25519 natively, and that same key already signs
    # commits and authenticates the Codeberg remote. One key to hold and
    # rotate, no separate GPG or age identity to provision.
    #
    # NB agenix decrypts at ACTIVATION, never at evaluation, so it can only
    # ever protect values a runtime consumer resolves for itself. Identity that
    # an eval consumes (the Proton account's generated prefs, rbw's
    # config.json, GECOS) cannot be hidden this way and is handled separately —
    # see the "eval-time identity" block in nix/system/defaults.nix.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative Flatpak, as a home-manager module (nix/home/base/flatpaks.nix).
    # Every GUI app in the portable profile is a Flathub ref now rather than a
    # nixpkgs derivation — see that file for the three apps that could not
    # follow and why.
    #
    # The home-manager module installs into the USER flatpak installation
    # (~/.local/share/flatpak), never the system one. That is what keeps this
    # usable on a foreign host: no root, nothing written outside $HOME, and
    # nothing that collides with a host distribution's own system-wide
    # flatpaks.
    #
    # `uninstallUnmanaged` is deliberately left at its default (false)
    # throughout: this profile is applied to machines that already have
    # flatpaks installed by hand, and a module that removes everything it did
    # not declare would delete them on the first switch.
    nix-flatpak.url = "github:gmodena/nix-flatpak";

    # devenv backs devShells.default (flake/devenv.nix), replacing the
    # hand-rolled mkShell that used to live in flake/devshell.nix. It supplies
    # the Rust toolchain, the dev scripts and the git hooks declaratively.
    #
    # It is not only a devShell input any more: nix/home/base/pkgs.nix calls
    # `devenv.lib.mkConfig` on flake/languages.nix — the same module the dev
    # shell imports — and installs the resulting toolchains into the user
    # profile, so the compilers the shell offers and the compilers on the
    # machine's PATH are one declaration rather than two lists kept in step by
    # hand. That path is module-system evaluation only; no shell is built, so
    # nothing below about `--no-pure-eval` applies to it.
    #
    # The entry point DID change: `nix develop --no-pure-eval`, or
    # `nix run .#dev`, which is the same call spelled once. devenv discovers
    # the checkout root from the environment, and pure flake evaluation hides
    # it — a plain `nix develop` gets a shell whose state and git hooks point
    # at a placeholder path (see flake/devenv.nix's `devenvRoot`, which exists
    # so `nix flake check` can still evaluate this output at all).
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # rycee's pre-packaged Firefox addons (Nix-pinned XPIs for the LibreWolf
    # profile in nix/home/apps/librewolf.nix) — the subflake, not the whole NUR.
    firefox-addons = {
      url = "gitlab:rycee/nur-expressions?dir=pkgs/firefox-addons";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # bun2nix vendors aipage's bun.lock JS deps (postcss/tailwind/autoprefixer)
    # for the in-flake aipage build (nix/packages/aipage.nix). Overlay applied to a
    # dedicated pkgs instance (pkgsBun) so the system closure's pkgs stays
    # overlay-free.
    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Millennium (SteamClientHomebrew/Millennium) is a theme/plugin loader for
    # the Steam desktop client. Only the `millennium` library package is
    # consumed: nix/modules/desktop/steam.nix calls upstream's `packages/nix/steam.nix`
    # against THIS repo's `pkgs.steam`, so the client and the whole FHS
    # closure stay on this repo's nixpkgs, and upstream's `overlays.default` /
    # `millennium-steam` package go unused. Same no-global-overlays reasoning
    # as bun2nix above.
    #
    # Deliberately NO `inputs.nixpkgs.follows = "nixpkgs"` here: upstream pins
    # nixpkgs to one commit because their Bun fixed-output-derivation hash is
    # bun-version-sensitive, and following ours would swap Bun and invalidate
    # that hash. Their own comment in packages/nix/flake.nix says: "Bun FOD is
    # sensitive to version changes, so we use a specific commit instead of a
    # channel."
    #
    # The cost: a second nixpkgs evaluation while Steam is on, and no binary
    # cache for the millennium library, so it compiles locally whenever
    # upstream cuts a release. The input tracks `main`; the nightly
    # `nix flake update` in nix/modules/services/maintenance.nix picks the bump up, and
    # `operation = "boot"` absorbs the compile before the next reboot.
    millennium.url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";
    # Hyprland is NOT a flake input: the system compositor comes from nixpkgs
    # (programs.hyprland in nix/modules/desktop/desktop.nix uses the module's default
    # `package = pkgs.hyprland`). nixpkgs' Hyprland is built by Hydra and lives
    # on cache.nixos.org (indefinite retention), so the prebuilt is always
    # substituted. A pinned Hyprland flake input was tried instead (for
    # independent version pinning) but its only prebuilt source —
    # hyprland.cachix.org — evicts old tagged builds (Hyprland's CI rebuilds
    # main with bumped inputs on every push, so a release tag ages out ~months
    # after release; v0.55.0's prebuilt was gone), and `inputs.nixpkgs.follows`
    # on that input additionally defeated the cache by changing input hashes.
    # Net: the flake-input route built the compositor from source on every
    # rebuild. See nix/modules/desktop/desktop.nix for the full rationale.
    # AIPage (codeberg.org/dasmatus/aipage) is NOT a flake input: its built
    # dist-* dirs are gitignored in the sibling repo and its flake only
    # exposes an impure `apps.build`, so no flake input can reach a built
    # artifact. Instead nix/packages/aipage.nix fetchgit-pins `main` at a hash-
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
      # Standalone home-manager (flake/home.nix) — the non-NixOS build. It
      # takes `nixpkgs` rather than the shared `pkgs` because it must apply
      # its own allowUnfreePredicate to the instance it hands to
      # home-manager; see that file's header for why a `nixpkgs.config` set
      # inside the HM modules would be ignored instead.
      homeConfigs = import ./flake/home.nix {
        inherit
          inputs
          nixpkgs
          system
          settings
          aipagePackages
          ;
      } self;
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
        inherit
          pkgs
          aipagePackages
          pkgsClaude
          inputs
          ;
      } self;

      # Task-runner apps — the retired Justfile, now nix-native. See
      # flake/apps.nix.
      apps.${system} = import ./flake/apps.nix {
        inherit pkgs;
        lib = nixpkgs.lib;
      } self;

      formatter.${system} = pkgs.nixfmt-tree;

      homeConfigurations = homeConfigs;

      # Rust dev shell, built by devenv from flake/devenv.nix. Still exposed
      # as devShells.default, so `nix develop` and direnv's `use flake` are
      # unaffected by the move off mkShell.
      devShells.${system}.default = inputs.devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [ ./flake/devenv.nix ];
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
