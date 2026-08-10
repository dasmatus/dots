# Hardware configuration via nixos-facter — replaces the retired per-CPU-vendor
# nix/hosts/{intel,amd}.nix variants (git history). The facter NixOS modules
# ship in nixpkgs (auto-imported, namespace hardware.facter.*): a real report
# drives microcode, firmware, GPU initrd modules, amd_pstate, DHCP and
# hostPlatform. The installer generates nix/facter.json on the target; the
# committed stub ({}) keeps evaluation green with detection off. Adoption on
# an existing machine: sudo nixos-facter -o nix/facter.json, then rebuild.
#
# NVIDIA is deliberately not auto-configured upstream (facter filters out
# nouveau), so it is switched via if-then-else on the parsed report.
# PCI ids are decimal in facter reports: 4318 == 0x10de (NVIDIA).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  report = config.hardware.facter.report;
  hasNvidia = builtins.any (card: (card.vendor.value or 0) == 4318) (
    report.hardware.graphics_card or [ ]
  );
in
{
  hardware.facter.reportPath = ./facter.json;

  # The nvidia module gates the whole driver on this list containing "nvidia"
  # — also on this Wayland-only Hyprland setup where no X server ever runs.
  # mkForce discards facter's own graphics-module contribution (it appends a
  # duplicate "modesetting" on real reports) so the flake checks hold on any machine.
  services.xserver.videoDrivers = lib.mkForce (if hasNvidia then [ "nvidia" ] else [ "modesetting" ]);

  # GTX 1660 SUPER = Turing TU116 → open kernel modules (upstream suggestion).
  hardware.nvidia =
    if hasNvidia then
      {
        open = true;
        modesetting.enable = true;
        powerManagement.enable = false;
      }
    else
      { };

  # Local model server for the fish `claude`/`codex` launch aliases and as
  # an optional Codex model_provider. Gated on the installer "AI" screen
  # toggle (options.dots.ai.ollama, written into settings.nix as aiOllama);
  # models + modelsDir come from the dots.ai.* options (defaults in
  # nix/defaults.nix) instead of being hardcoded here. modelsDir is the
  # persist-bound /var/lib/ollama/models (impermanence.nix pins /var/lib/ollama
  # so models survive the tmpfs root wipe — without it `loadModels` would
  # re-download every boot).
  services.ollama = lib.mkIf config.dots.ai.ollama {
    enable = true;
    # Static `ollama` user — paired with the DynamicUser override below. The
    # nixpkgs ollama module forces DynamicUser=true, which relocates the
    # StateDirectory to /var/lib/private/ollama and tries to migrate the
    # pre-existing public /var/lib/ollama (our impermanence bind-mount) into
    # it; rename() on a mountpoint is EBUSY, ollama fails 238/STATE_DIRECTORY
    # at every (re)start, and switch-to-configuration then exits status 4 —
    # aborting `nixos-rebuild switch`. A static user + DynamicUser=false keeps
    # the StateDirectory as the public /var/lib/ollama bind-mount (no
    # migration, no EBUSY) so models actually persist as intended.
    user = "ollama";
    loadModels = config.dots.ai.ollamaModels;
    modelsDir = config.dots.ai.ollamaModelsDir;
    package = if hasNvidia then pkgs.ollama-cuda else pkgs.ollama-rocm;
  };
  # See the services.ollama.user comment above for why DynamicUser must be off
  # under impermanence — without this override the module's DynamicUser=true
  # wins (priority 100) and the StateDirectory migration hits EBUSY.
  systemd.services.ollama.serviceConfig.DynamicUser =
    lib.mkIf config.dots.ai.ollama (lib.mkForce false);
  # The nixpkgs module lists modelsDir in ReadWritePaths but only the parent
  # in StateDirectory. ReadWritePaths is a mount-namespace directive: systemd
  # neither creates nor chowns it and *requires* it to pre-exist. Under
  # impermanence the tmpfs root means /var/lib/ollama/models is absent on a
  # fresh boot → namespace setup fails 226/NAMESPACE before ollama can mkdir
  # it; and when it does exist root-owned (hand-created) ollama can't write
  # blobs → permission denied. Putting it in StateDirectory makes systemd
  # create+chown it to the ollama user at the STATE_DIRECTORY step, which runs
  # *before* namespace setup and is proven to work here — it already
  # creates+chowns /var/lib/ollama (and .ollama) through the impermanence
  # bind-mount. Self-heals every boot, no manual mkdir/chown.
  systemd.services.ollama.serviceConfig.StateDirectory =
    lib.mkIf config.dots.ai.ollama (lib.mkForce [ "ollama" "ollama/models" ]);
  # Facter only enables this when the report lists a monitor; keep the old
  # hosts/{intel,amd}.nix guarantee unconditionally.
  hardware.graphics.enable = true;
}
