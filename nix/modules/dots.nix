# Installer-managed configuration as typed NixOS options.
#
# flake/lib.nix builds `settings = (import ../nix/defaults.nix) //
# (import ../nix/settings.nix)` and passes it to every nixosSystem as
# specialArgs: nix/defaults.nix holds the non-install-time defaults and the
# installer TUI (rust/installer-tui) rewrites the install answers into
# nix/settings.nix on the target. Consumers used to read the flat `settings.*`
# attrset directly — which worked but left every key untyped/undocumented and
# the AI + ollama + path knobs hardcoded in nix/hosts.nix etc.
#
# This module bridges that flat attrset to typed `dots.*` options so consumers
# read `config.dots.*` instead of hardcoding `settings.*` keys. Every bridge
# uses mkDefault, so a direct `config.dots.* = …` assignment in another module
# still wins over the installer/defaults values. The installer-written subset
# (username, hostname, disks, swapSize, gitName, gitEmail + the three AI
# toggles) and the path knobs are declared here; the user-editable defaults.nix
# knobs (timezone, locale, desktop, boot, network) stay as `settings.*` reads
# — they are NOT installer-managed, so they don't get dots options.
#
# `config.dots` is also handed to Home Manager (nix/modules/users.nix
# extraSpecialArgs) so the HM-side AI gating (nix/home/{claude,codex}.nix) and
# the dots-clone symlinks (nix/home/dots-repo.nix) read the same typed values.
{
  lib,
  settings,
  ...
}:
let
  inherit (lib) mkOption mkDefault types;
in
{
  options.dots = {
    # --- Install answers (written by the installer TUI into settings.nix) ---
    username = mkOption {
      type = types.str;
      description = "Primary login name (installer-collected).";
    };
    hostname = mkOption {
      type = types.str;
      description = "RFC 1123 host label (installer-collected; empty defaults to \"tokyonight\").";
    };
    disks = mkOption {
      type = types.listOf types.str;
      description = "Target disk paths spanning the LVM volume group (installer-collected).";
    };
    swapSize = mkOption {
      type = types.str;
      description = "Swap size as a Nix string with unit, e.g. \"32G\" (installer-collected).";
    };
    gitName = mkOption {
      type = types.str;
      description = "Git user.name (installer-collected; also used as the GECOS full name).";
    };
    gitEmail = mkOption {
      type = types.str;
      description = "Git user.email (installer-collected).";
    };

    # --- AI tooling (toggled by the installer TUI "AI" screen) ---
    ai = {
      claude = mkOption {
        type = types.bool;
        description = "Enable Claude Code Home Manager config (nix/home/claude.nix).";
      };
      codex = mkOption {
        type = types.bool;
        description = "Enable Codex CLI Home Manager config (nix/home/codex.nix).";
      };
      ollama = mkOption {
        type = types.bool;
        description = "Enable the system + Home Manager ollama services (nix/hosts.nix, nix/home/codex.nix).";
      };
      ollamaModels = mkOption {
        type = types.listOf types.str;
        description = "Models ollama auto-pulls on service start (services.ollama.loadModels).";
      };
      ollamaModelsDir = mkOption {
        type = types.str;
        description = ''
          Where ollama reads/downloads models (services.ollama.modelsDir →
          OLLAMA_MODELS). MUST be on a /persist-bound path: impermanence.nix
          pins /var/lib/ollama, so the default survives the tmpfs root wipe —
          pointing this elsewhere requires persisting the target manually or
          models re-download every boot.
        '';
      };
    };

    # --- Paths ---
    paths = {
      stateDir = mkOption {
        type = types.str;
        description = ''
          Canonical install-answer stash. impermanence.nix bind-mounts
          /persist over this; the installer stashes settings.nix + facter.json
          here (rust/installer-tui/src/install.rs), and the first-login
          dots-clone service symlinks nix/settings.nix + nix/facter.json at
          it. Override together with the impermanence entry AND the installer
          stash path (rust/installer-tui/src/install.rs hardcodes
          /mnt/persist/var/lib/dots) — the default is the only coherent value.
        '';
      };
      settingsFile = mkOption {
        type = types.str;
        default = "settings.nix";
        description = "Basename of the install-answers file under paths.stateDir.";
      };
      facterFile = mkOption {
        type = types.str;
        default = "facter.json";
        description = "Basename of the nixos-facter report under paths.stateDir.";
      };
    };
  };

  # Bridge the flat `settings` attrset (defaults.nix // settings.nix) to the
  # typed options above. defaults.nix provides every key so `settings.<key>`
  # always resolves; the installer-written settings.nix overrides the
  # installer-managed subset on the target.
  config.dots = {
    username = mkDefault settings.username;
    hostname = mkDefault settings.hostname;
    disks = mkDefault settings.disks;
    swapSize = mkDefault settings.swapSize;
    gitName = mkDefault settings.gitName;
    gitEmail = mkDefault settings.gitEmail;
    ai = {
      claude = mkDefault settings.aiClaude;
      codex = mkDefault settings.aiCodex;
      ollama = mkDefault settings.aiOllama;
      ollamaModels = mkDefault settings.aiOllamaModels;
      ollamaModelsDir = mkDefault settings.aiOllamaModelsDir;
    };
    paths.stateDir = mkDefault settings.dotsStateDir;
  };
}
