# Installer-managed configuration as typed NixOS options.
#
# flake/lib.nix builds `settings = (import ../nix/system/defaults.nix) //
# (import ../nix/data/settings.nix)` and passes it to every nixosSystem as
# specialArgs: nix/system/defaults.nix holds the non-install-time defaults and the
# installer TUI (rust/installer-tui) rewrites the install answers into
# nix/data/settings.nix on the target. Consumers used to read the flat `settings.*`
# attrset directly — which worked but left every key untyped/undocumented and
# the AI + ollama + path knobs hardcoded in nix/system/hosts.nix etc.
#
# This module bridges that flat attrset to typed `dots.*` options so consumers
# read `config.dots.*` instead of hardcoding `settings.*` keys. Every bridge
# uses mkDefault, so a direct `config.dots.* = …` assignment in another module
# still wins over the installer/defaults values. The installer-written subset
# (username, hostname, disks, swapSize + the three AI
# toggles) and the path knobs are declared here; the user-editable defaults.nix
# knobs (timezone, locale, desktop, boot, network) stay as `settings.*` reads
# — they are NOT installer-managed, so they don't get dots options.
#
# The idle timeouts are the exception to that split, and the reason is worth
# recording: they are the one user-editable pair a SINGLE host may need to
# disagree with the others about (a laptop that lives in a bag and a tower in
# a locked room want different numbers), and `settings.*` is one flat file
# with no per-host override. An option takes a `dots.idle.lockTimeout = …`
# from a host module and mkDefault still lets the flat file win everywhere
# else. `types.int` also stops a quoted "600" reaching the shell as a string.
#
# `config.dots` is also handed to Home Manager (nix/modules/system/users.nix
# extraSpecialArgs) so the HM-side AI gating (nix/home/{claude,codex}.nix) and
# the dots-clone symlinks (nix/home/base/dots-repo.nix) read the same typed values.
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

    # --- AI tooling (toggled by the installer TUI "AI" screen) ---
    ai = {
      claude = mkOption {
        type = types.bool;
        description = "Enable Claude Code Home Manager config (nix/home/ai/claude.nix).";
      };
      codex = mkOption {
        type = types.bool;
        description = "Enable Codex CLI Home Manager config (nix/home/ai/codex.nix).";
      };
      ollama = mkOption {
        type = types.bool;
        description = "Enable the system + Home Manager ollama services (nix/system/hosts.nix, nix/home/ai/codex.nix).";
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

    # --- Idle (read by nix/home/desktop/quickshell/default.nix) ---
    idle = {
      blankTimeout = mkOption {
        type = types.int;
        description = ''
          Seconds of inactivity before the shell turns the outputs off
          (`hyprctl dispatch dpms off`). Read by
          nix/home/desktop/quickshell/default.nix, which writes it into
          ~/.config/dots-shell/idle.json for qml/idle/IdleWatcher.qml.
        '';
      };
      lockTimeout = mkOption {
        type = types.int;
        description = ''
          Seconds of inactivity before the shell locks the session
          (`loginctl lock-session`, which services.systemd-lock-handler
          routes to the existing hyprlock.service through lock.target). A
          value below blankTimeout pulls the blank in to meet it rather than
          delaying the lock. Zero or negative means "use the default", not
          "never": auto-lock is deliberately not switchable off from here.
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
          dots-clone service symlinks nix/data/settings.nix + nix/data/facter.json at
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

    # --- Desktop environment ---
    desktop = {
      environment = mkOption {
        type = types.enum [
          "gnome"
          "hyprland"
          "sway"
        ];
        default = "hyprland";
        description = ''
          Which desktop environment the session runs. Exactly one is active
          at a time; the enum makes mutual exclusion structural rather than
          asserted. Each DE has its own system module
          (nix/modules/desktop/<name>.nix) and home module
          (nix/home/desktop/<name>.nix), both gated on this value.
        '';
      };

      hyprland = {
        layout = mkOption {
          type = types.enum [
            "dwindle"
            "master"
          ];
          default = "dwindle";
          description = "Hyprland tiling layout algorithm.";
        };
      };

      sway = {
        gaps = mkOption {
          type = types.int;
          default = 5;
          description = "Sway inner gaps in pixels.";
        };
      };
    };

    # --- Optional subsystems, off by default (Phase C hardening pass) ---
    virtualisation.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable the libvirt/QEMU stack
        (nix/modules/system/virtualisation.nix: libvirtd, virt-manager, OVMF,
        swtpm). Previously always on; now off by default so the attack
        surface of a full VM host (a privileged libvirtd, QEMU, its
        AppArmor/SELinux-adjacent helpers) is not paid on every install
        unconditionally. Set true on a host that actually runs VMs.
      '';
    };

    xwayland.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether Hyprland runs an XWayland server
        (nix/modules/desktop/hyprland.nix: programs.hyprland.xwayland.enable).
        Phase C tried removing XWayland outright on the premise that the
        whole GUI set is Wayland-native Flatpaks, but two apps on this
        machine need it: Haveno (nix/home/base/pkgs.nix) is a JavaFX/jpackage
        bundle and OpenJFX has no Wayland backend, and Steam
        (nix/modules/desktop/steam.nix) is an X11-only client whose need only
        shows up once nixos-facter sees the real AMD GPU on hardware — the
        tracked config's `{}` facter stub hides that, and session-boot cannot
        catch it either since it never launches either app. Default true
        keeps both working; flip to false only once Haveno and Steam are
        both gone, since that is the actual precondition the Phase C removal
        assumed.
      '';
    };

    kernel = {
      harden = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether nix/modules/system/kernel.nix's from-source Clang
          CFI + ThinLTO kernel (Phase A,
          docs/superpowers/specs/2026-09-08-hardening-design.md) replaces
          the stock `pkgs.linuxPackages_latest` kernel
          (nix/modules/system/core.nix used to set this directly; that line
          now lives in kernel.nix, switched on this option). Defaults on
          for tokyonight — this is the one phase of the hardening project
          that can make the machine fail to BOOT, so it stays one boolean
          away from the stock kernel. A `stock-kernel` specialisation
          (kernel.nix) also flips this off for a second, always-present
          Limine boot entry, so recovering from a bad boot never depends on
          a working system to flip the option and rebuild.
        '';
      };

      nvidiaCfiMatched = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether the nvidia-open kernel module in this closure was
          rebuilt against the CFI-enforcing kernel's own
          stdenv/makeFlags (Phase A2 / Task 8). Stays false — and the
          assertion in nix/system/hosts.nix stays tripped — until that
          override actually lands, so `hardware.nvidia.open` and
          `dots.kernel.harden` can never silently combine into an
          out-of-tree module that traps on its first indirect call under
          a kCFI-enforcing kernel. Task 8's own commit is expected to flip
          this to true once its build is verified.
        '';
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
    ai = {
      claude = mkDefault settings.aiClaude;
      codex = mkDefault settings.aiCodex;
      ollama = mkDefault settings.aiOllama;
      ollamaModels = mkDefault settings.aiOllamaModels;
      ollamaModelsDir = mkDefault settings.aiOllamaModelsDir;
    };
    idle = {
      blankTimeout = mkDefault settings.idleBlankTimeout;
      lockTimeout = mkDefault settings.idleLockTimeout;
    };
    paths.stateDir = mkDefault settings.dotsStateDir;
    desktop.environment = mkDefault settings.desktop;
  };
}
