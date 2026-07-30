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
    loadModels = config.dots.ai.ollamaModels;
    modelsDir = config.dots.ai.ollamaModelsDir;
    package = if hasNvidia then pkgs.ollama-cuda else pkgs.ollama-rocm;
  };
  # Facter only enables this when the report lists a monitor; keep the old
  # hosts/{intel,amd}.nix guarantee unconditionally.
  hardware.graphics.enable = true;
}
