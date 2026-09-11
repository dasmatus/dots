# homeConfigurations — the standalone home-manager build, for hosts that are
# not this repo's NixOS system.
#
# The NixOS path (flake/nixos.nix) installs home-manager AS A NIXOS MODULE, so
# the home profile gets `pkgs`, the unfree predicate, `dots` and `settings`
# from the system evaluation for free. Nothing here has a system evaluation to
# borrow from, so this file supplies each of those explicitly. Everything it
# reconstructs is a value the NixOS side derives the same way — see the
# per-binding comments — so the two builds see the same inputs, not merely
# similar ones.
#
# Only the PORTABLE half of the profile is installed: see
# nix/home/profiles/portable.nix and its session.nix counterpart for where the
# line falls and why (runtime coupling — a Hyprland seat, which a foreign
# host has no compositor to hand out — not module hygiene).
{
  inputs,
  nixpkgs,
  system,
  settings,
  aipagePackages,
}:
self:
let
  lib = nixpkgs.lib;

  # The unfree allowlist. On NixOS this is nix/modules/system/core.nix's
  # `nixpkgs.config.allowUnfreePredicate`, applied to the system `pkgs` that
  # home-manager then inherits through `useGlobalPkgs`. A standalone build
  # takes `pkgs` as an argument instead, and home-manager IGNORES a
  # `nixpkgs.config` set inside its own modules when `pkgs` is passed in (it
  # warns and carries on), so the predicate has to be applied HERE, to the
  # instance handed over, or every unfree package below is simply refused.
  #
  # This is the subset of core.nix's list that the portable profile can
  # actually reach: the nvidia and steam entries there are driven by
  # nix/system/hosts.nix and nix/modules/desktop/steam.nix, both NixOS-only, so
  # including them would be dead weight that quietly widens what this build is
  # permitted to install.
  #
  # "obsidian" left with it. Obsidian is a Flathub ref now
  # (nix/home/base/flatpaks.nix), so no evaluation here can reach the unfree
  # nixpkgs package — and a licence allowance for something nothing installs
  # is exactly the kind of quiet widening this list is trimmed to avoid.
  # core.nix keeps its entry: that is the NixOS side's list, and the session
  # profile is not in scope here.
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "claude-code"
        "claude-desktop"
        "presence.nvim"
        "vscode-extension-fill-labs-dependi"
        "cisco-packet-tracer"
      ];
  };

  # Mirrors nix/modules/dots.nix's `config.dots` bridge. That file is a NixOS
  # module — it declares `options.dots`, so it cannot be imported into a
  # home-manager evaluation — but the home modules only ever read the resulting
  # VALUES out of the `dots` specialArg, never the option machinery. So the
  # bridge is reproduced here as a plain attrset over the same `settings`.
  #
  # Restricted to the fields the portable profile reads (`ai.*` for the AI
  # harness modules, `paths.*` for nix/home/base/dots-repo.nix). `dots.session.*`
  # is deliberately absent: it belongs to nix/home/desktop/session, which lives
  # in the session profile and is not installed here — an unused stub would
  # only invite that module to be added back without noticing it needs a seat.
  dots = {
    username = settings.username;
    hostname = settings.hostname;
    ai = {
      claude = settings.aiClaude;
      codex = settings.aiCodex;
      ollama = settings.aiOllama;
    };
    paths = {
      stateDir = settings.dotsStateDir;
      settingsFile = "settings.nix";
      facterFile = "facter.json";
    };
  };

  configuration = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;

    extraSpecialArgs = {
      inherit inputs settings dots;
      # The same in-flake packages nix/modules/system/users.nix threads into the
      # NixOS home-manager instance, under the camelCase names the home modules
      # destructure. Taken from `self.packages` rather than re-derived, so the
      # standalone build and the NixOS build share one definition — and one
      # store path — per package. (aipage is the exception: `self.packages`
      # exposes it as aipage-firefox/aipage-chrome, but those are the very same
      # derivations as aipagePackages.firefox/.chrome, which is what
      # flake/packages.nix builds them from.)
      claudeDesktop = self.packages.${system}.claude-desktop;
      betterbird = self.packages.${system}.betterbird;
      chromaleon = self.packages.${system}.chromaleon;
      settingsMenu = self.packages.${system}.settings;
      aipageFirefox = aipagePackages.firefox;
      aipageChrome = aipagePackages.chrome;
    };

    modules = [
      # agenix's home-manager module — declares `age.secrets` and the
      # activation step that decrypts them. Required by
      # nix/home/secrets/identity.nix, which the portable profile imports and
      # which is what supplies the git identity this repo no longer commits.
      inputs.agenix.homeManagerModules.default
      # nixvim's home-manager module — declares `programs.nixvim`, which
      # nix/home/apps/nixvim.nix (imported by the portable profile) assigns to.
      # This and agenix above are exactly the pair
      # nix/modules/system/users.nix passes as `sharedModules` on the NixOS
      # side; the two lists must stay in step, because a module missing here
      # does not fail as "module missing" — it fails as "the option
      # `programs.nixvim' does not exist", pointing at the innocent consumer
      # rather than at this list.
      inputs.nixvim.homeModules.nixvim
      # nix-flatpak's home-manager module — declares `services.flatpak`, which
      # nix/home/base/flatpaks.nix assigns to. Same both-entry-points rule as
      # the two above: it is listed in nix/modules/system/users.nix's
      # sharedModules as well, and a profile that imports flatpaks.nix without
      # it fails as "the option `services.flatpak' does not exist".
      inputs.nix-flatpak.homeManagerModules.nix-flatpak
      ../nix/home/profiles/portable.nix
      ../nix/home/foreign/nix-on-path.nix
      # A function module rather than a line in the attrset below, because it
      # has to read `config`: git's package here is
      # `pkgs.git.override { withLibsecret = true; }`
      # (nix/home/shell/git.nix), and plain `pkgs.git` is a DIFFERENT
      # derivation without the credential helper this carve-out exists to
      # deliver. Naming the option is the only way to get the right one.
      (
        { config, ... }:
        {
          # genericLinux above fixes XDG_DATA_DIRS so the host's shell SEES
          # the profile's desktop entries and icons. It does nothing about
          # PATH, and on secureblue ~/.nix-profile/bin is on no session PATH,
          # so GLib discards every .desktop entry whose Exec or TryExec is a
          # bare name it cannot resolve: installed, listed, and still absent
          # from the app grid. See nix/home/foreign/nix-on-path.nix.
          #
          # Foreign-host-only, which is why it is imported here and not from
          # portable.nix: on NixOS /usr/bin is empty and ~/.local/bin is on no
          # PATH, so the same farm would shadow the system profile.
          targets.foreignHost.localBin = {
            enable = true;
            nixWinsPackages = [ config.programs.git.package ];
          };
        }
      )
      {
        home.username = settings.username;
        home.homeDirectory = "/home/${settings.username}";
        # home.stateVersion is deliberately NOT set here — it belongs to
        # nix/home/profiles/portable.nix, so both builds inherit one value.
        # `types.enum` merges equal definitions without complaint, so a
        # duplicate here would evaluate fine today and then silently diverge
        # the day one of the two is bumped. stateVersion selects module
        # DEFAULTS (gtk4 theme inheritance among them), so divergence means
        # the same profile behaving differently on the two hosts.

        # Everything below is what a NixOS host provides for free and a
        # foreign distribution does not.
        #
        # genericLinux teaches the profile that it is a guest: it prepends the
        # home profile to XDG_DATA_DIRS (so .desktop entries and icons
        # installed here are seen by a host-provided GNOME/KDE session rather
        # than silently ignored), and wraps the session so nix-installed
        # binaries find the host's locale archive instead of aborting on a
        # missing locale. Setting it on NixOS would be wrong — hence its
        # absence from the shared portable profile — which is exactly the kind
        # of host-specific fact this file exists to carry.
        targets.genericLinux.enable = true;

        # On NixOS, nix/modules/system/core.nix installs fonts system-wide via
        # `fonts.packages`. A standalone profile has no such hook, so
        # fontconfig has to be told to look inside the home profile or every
        # Nerd Font glyph this config's terminal, editor and shell prompt
        # assume falls back to tofu.
        fonts.fontconfig.enable = true;
      }
    ];
  };
in
# One configuration, exposed under two names — an alias, not a second build:
# both attributes are the same `configuration` value, so they evaluate once and
# share every store path.
#
#   "user@host"  is what `home-manager switch --flake .#` looks for FIRST: with
#                no attribute after the `#` it derives one from
#                $USER@$(hostname -s).
#   "user"       is the fallback home-manager tries when that misses, and it is
#                the one that actually carries this machine today: the running
#                host is named independently of `settings.hostname`, which is
#                an INSTALL ANSWER for the NixOS system (it becomes
#                networking.hostName) and not a description of whatever
#                foreign box the portable profile is being applied to. Those
#                two agreeing is a coincidence, not an invariant — and when
#                they disagree, the "user@host" key names a host that does not
#                exist while `--flake .#` asks for one that has no attribute.
#                Rather than couple the standalone build to the NixOS
#                machine's name, the bare-username alias makes `--flake .#`
#                resolve on any host this user logs into.
#
# A second machine that wants its OWN profile adds its own "user@host" key
# beside these; only the unqualified fallback is shared.
{
  "${settings.username}@${settings.hostname}" = configuration;
  ${settings.username} = configuration;
}
