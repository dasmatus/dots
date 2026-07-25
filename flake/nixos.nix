# nixosConfigurations — the installed `tokyonight` system + the two LiveISO
# closures (lean + full). Hardware is not baked into variants: nix/hosts.nix
# reads the nixos-facter report the installer generates on the target.
{
  inputs,
  nixpkgs,
  settings,
  mkIso,
  ...
}:
{
  # Hardware is not baked into variants anymore: nix/hosts.nix reads the
  # nixos-facter report the installer generates on the target.
  tokyonight = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs settings;
      aipageFirefox = inputs.self.packages.x86_64-linux.aipage-firefox;
      aipageChrome = inputs.self.packages.x86_64-linux.aipage-chrome;
    };
    modules = [
      inputs.disko.nixosModules.disko
      inputs.home-manager.nixosModules.home-manager
      inputs.lanzaboote.nixosModules.lanzaboote
      (import ../nix/disko.nix { inherit (settings) disks swapSize; })
      ../nix/modules/core.nix
      ../nix/modules/boot.nix
      ../nix/modules/network.nix
      ../nix/modules/searxng.nix
      ../nix/modules/virtualisation.nix
      ../nix/modules/users.nix
      ../nix/modules/hardening.nix
      ../nix/modules/maintenance.nix
      ../nix/modules/secureboot.nix
      ../nix/modules/desktop.nix
      ../nix/modules/form-factor.nix
      ../nix/hosts.nix
    ];
  };
  # Lean by default: the flake rides on the ISO, packages come from the
  # binary cache during install. live-iso-full embeds the prebuilt system
  # closure for offline installs (much bigger image).
  live-iso = mkIso false;
  live-iso-full = mkIso true;
}
