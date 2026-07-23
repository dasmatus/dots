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

  services.ollama = {
    enable = true;
    loadModels = [
      "ornith:9b"
      "gemma4:e4b"
    ];
    package = if hasNvidia then pkgs.ollama-cuda else pkgs.ollama-rocm;
  };
  # Facter only enables this when the report lists a monitor; keep the old
  # hosts/{intel,amd}.nix guarantee unconditionally.
  hardware.graphics.enable = true;
}
