# Hardware configuration via nixos-facter, replaces the retired per-CPU-vendor
# nix/hosts/{intel,amd}.nix variants (git history). The facter NixOS modules
# ship in nixpkgs (auto-imported, namespace hardware.facter.*): a real report
# drives microcode, firmware, GPU initrd modules, amd_pstate, DHCP and
# hostPlatform. The installer generates nix/data/facter.json on the target; the
# committed stub ({}) keeps evaluation green with detection off. Adoption on
# an existing machine: sudo nixos-facter -o nix/data/facter.json, then rebuild.
#
# NVIDIA is deliberately not auto-configured upstream (facter filters out
# nouveau), so it is switched via if-then-else on the parsed report.
# PCI ids are decimal in facter reports: 4318 == 0x10de (NVIDIA).
{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  report = config.hardware.facter.report;
  hasNvidia = builtins.any (card: (card.vendor.value or 0) == 4318) (
    report.hardware.graphics_card or [ ]
  );
in
{
  hardware.facter.reportPath = ../data/facter.json;

  # The nvidia module gates the whole driver on this list containing "nvidia",
  # also on this Wayland-only Hyprland setup where no X server ever runs.
  # mkForce discards facter's own graphics-module contribution (it appends a
  # duplicate "modesetting" on real reports) so the flake checks hold on any machine.
  services.xserver.videoDrivers = lib.mkForce (if hasNvidia then [ "nvidia" ] else [ "modesetting" ]);

  # GTX 1660 SUPER = Turing TU116 → open kernel modules (upstream suggestion).
  #
  # `package` is spelled out rather than left on its default (Task 8 / Phase
  # A2) even though, on this pin, the default already resolves to the same
  # place: `hardware.nvidia.package` defaults to
  # `config.boot.kernelPackages.nvidiaPackages.${branch}`
  # (nixos/modules/hardware/video/nvidia.nix), and `boot.kernelPackages` is
  # `hardenedKernelPackages` (kernel.nix) whenever `dots.kernel.harden` is on
  # — so nvidia-open already gets built through the hardened kernel's own
  # `pkgs.linuxPackagesFor` scope, not a stock one, with no override needed
  # here. Writing it out anyway is a deliberate pin against a future
  # nixpkgs change to `branch`'s default (currently "stable") silently
  # retargeting this: `flake/checks.nix`'s `nvidia-cfi-toolchain-eval` reads
  # `config.hardware.nvidia.package.open` directly, so this line is that
  # check's own contract with the option, not decoration.
  hardware.nvidia =
    if hasNvidia then
      {
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        open = true;
        modesetting.enable = true;
        powerManagement.enable = false;
      }
    else
      { };

  # `dots-secreport triage --assist` (nix/home/ai/triage-assist.nix) is a TRIAGE-ONLY
  # consumer of the same services.ollama below. It is never a reason to flip
  # dots.ai.ollama on, and this warning is purely advisory (the triage
  # subcommand already degrades to heuristics-only, without hanging, when
  # ollama is unreachable; see the contract). It exists only to catch the
  # "enabled the assist flag, forgot ollama is off" case at rebuild time
  # instead of silently at first triage invocation.
  warnings = lib.optional (settings.triageAssistEnable && !config.dots.ai.ollama) ''
    settings.triageAssistEnable is on but dots.ai.ollama is off: `dots-secreport triage --assist` will find nothing at ${settings.aiOllamaEndpoint} and fall back to heuristics-only until services.ollama is enabled.
  '';

  # Local model server for the fish `claude`/`codex` launch aliases and as
  # an optional Codex model_provider. Gated on the installer "AI" screen
  # toggle (options.dots.ai.ollama, written into settings.nix as aiOllama);
  # models + modelsDir come from the dots.ai.* options (defaults in
  # nix/system/defaults.nix) instead of being hardcoded here. modelsDir is the
  # persist-bound /var/lib/ollama/models (impermanence.nix pins /var/lib/ollama
  # so models survive the tmpfs root wipe, without it `loadModels` would
  # re-download every boot).
  # Phase B, ruling R6: before copying the searxng-keygen directive set here
  # too, read what nixpkgs' own ollama module (nixos/modules/services/misc/
  # ollama.nix) already ships on `systemd.services.ollama.serviceConfig`.
  # It already carries the entire searxng set and then some: NoNewPrivileges,
  # ProtectSystem=strict, ProtectHome=true, PrivateTmp=true,
  # ProtectKernelTunables=true, ProtectKernelModules=true,
  # ProtectControlGroups=true, RestrictNamespaces=true, LockPersonality=true,
  # MemoryDenyWriteExecute=true, RestrictRealtime=true, RestrictSUIDSGID=true,
  # RestrictAddressFamilies=[AF_INET AF_INET6 AF_UNIX],
  # CapabilityBoundingSet=[""] (empty), plus PrivateUsers=true,
  # ProtectProc="invisible", RemoveIPC=true, DevicePolicy="closed" and a
  # SystemCallFilter this repo did not have to write. There is nothing left
  # to add: the honest finding for this unit is that upstream already meets
  # or exceeds the searxng baseline, and restating the same directives here
  # would be decoration, not hardening. The DynamicUser/StateDirectory
  # overrides below exist for the impermanence interaction, not security —
  # PrivateUsers=true still applies its own user-namespace mapping on top of
  # the static uid, so trading DynamicUser for a static user costs nothing
  # here.
  services.ollama = lib.mkIf config.dots.ai.ollama {
    enable = true;
    # Static `ollama` user, paired with the DynamicUser override below. The
    # nixpkgs ollama module forces DynamicUser=true, which relocates the
    # StateDirectory to /var/lib/private/ollama and tries to migrate the
    # pre-existing public /var/lib/ollama (our impermanence bind-mount) into
    # it; rename() on a mountpoint is EBUSY, ollama fails 238/STATE_DIRECTORY
    # at every (re)start, and switch-to-configuration then exits status 4,
    # aborting `nixos-rebuild switch`. A static user + DynamicUser=false keeps
    # the StateDirectory as the public /var/lib/ollama bind-mount (no
    # migration, no EBUSY) so models actually persist as intended.
    user = "ollama";
    loadModels = config.dots.ai.ollamaModels;
    modelsDir = config.dots.ai.ollamaModelsDir;
    package = if hasNvidia then pkgs.ollama-cuda else pkgs.ollama-rocm;
  };
  # See the services.ollama.user comment above for why DynamicUser must be off
  # under impermanence. Without this override the module's DynamicUser=true
  # wins (priority 100) and the StateDirectory migration hits EBUSY.
  systemd.services.ollama.serviceConfig.DynamicUser = lib.mkIf config.dots.ai.ollama (
    lib.mkForce false
  );
  # The nixpkgs module lists modelsDir in ReadWritePaths but only the parent
  # in StateDirectory. ReadWritePaths is a mount-namespace directive: systemd
  # neither creates nor chowns it and *requires* it to pre-exist. Under
  # impermanence the tmpfs root means /var/lib/ollama/models is absent on a
  # fresh boot → namespace setup fails 226/NAMESPACE before ollama can mkdir
  # it; and when it does exist root-owned (hand-created) ollama can't write
  # blobs → permission denied. Putting it in StateDirectory makes systemd
  # create+chown it to the ollama user at the STATE_DIRECTORY step, which runs
  # *before* namespace setup and is proven to work here. It already
  # creates+chowns /var/lib/ollama (and .ollama) through the impermanence
  # bind-mount. Self-heals every boot, no manual mkdir/chown.
  systemd.services.ollama.serviceConfig.StateDirectory = lib.mkIf config.dots.ai.ollama (
    lib.mkForce [
      "ollama"
      "ollama/models"
    ]
  );
  # Facter only enables this when the report lists a monitor; keep the old
  # hosts/{intel,amd}.nix guarantee unconditionally.
  hardware.graphics.enable = true;

  # Phase A's silent-failure guard (R40): an out-of-tree module loaded into
  # a kCFI-enforcing kernel traps on its first indirect call unless it was
  # built with matching stdenv/makeFlags (nix/modules/system/kernel.nix,
  # Task 8 / Phase A2 does that work for hardware.nvidia.open). An
  # assertion, not a warning, because system.autoUpgrade
  # (nix/modules/services/maintenance.nix) runs this unattended: a warning
  # only reaches a build log nobody reads at 3am, while `operation = "boot"`
  # with `allowReboot = false` means the actual crash — a black screen —
  # only happens whenever the human next reboots, long after that log
  # scrolled past. An assertion is the only one of the two that can stop the
  # bad generation from being built and registered as the default in the
  # first place. It cannot fire on this machine today: the committed
  # facter.json stub leaves hasNvidia false, so the assertion's left side is
  # false here regardless. On the real tower it is a real gate until Task 8
  # flips dots.kernel.nvidiaCfiMatched, and dots.kernel.harden = false is
  # that machine's own escape hatch in the meantime.
  assertions = [
    {
      assertion = !(hasNvidia && config.dots.kernel.harden) || config.dots.kernel.nvidiaCfiMatched;
      message = ''
        hardware.nvidia.open is enabled (nixos-facter reported a 0x10de
        device) and dots.kernel.harden is on, but dots.kernel.nvidiaCfiMatched
        is not set. nixpkgs' own hardware.nvidia.open build is not compiled
        with this kernel's CFI/ThinLTO flags, and an out-of-tree module built
        without matching flags traps on its first indirect call under a
        kCFI-enforcing kernel — a black screen on next boot, not a readable
        failure.

        Either land Task 8 (Phase A2: override hardware.nvidia.open's
        derivation with the kernel's own llvmPackages stdenv and matching
        makeFlags) and set dots.kernel.nvidiaCfiMatched = true once it is
        verified, or set dots.kernel.harden = false on this machine to fall
        back to the stock kernel until it does.
      '';
    }
  ];
}
