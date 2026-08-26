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
let
  # The tokyonight module list + specialArgs, parameterized only by `settings`
  # so the VM install test (tests/default.nix) can build the closure with test
  # settings (disks=["/dev/vda"], swapSize="1G") and pre-substitute it via
  # mountHostNixStore — the committed-settings closure can't be reused because
  # disko's swapDevices/disk entries change the toplevel. `tokyonight` below is
  # `mkTokyonight settings` (committed settings), so this is behavior-preserving.
  mkTokyonight =
    s:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        settings = s;
        aipageFirefox = inputs.self.packages.x86_64-linux.aipage-firefox;
        aipageChrome = inputs.self.packages.x86_64-linux.aipage-chrome;
        wallpaperTui = inputs.self.packages.x86_64-linux.wallpaper-tui;
        hyprmon = inputs.self.packages.x86_64-linux.hyprmon;
        settingsMenu = inputs.self.packages.x86_64-linux.settings;
        claudeDesktop = inputs.self.packages.x86_64-linux.claude-desktop;
      };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.home-manager.nixosModules.home-manager
        inputs.impermanence.nixosModules.impermanence
        (import ../nix/disko.nix { inherit (s) disks swapSize; })
        ../nix/modules/dots.nix
        ../nix/modules/core.nix
        ../nix/modules/impermanence.nix
        ../nix/modules/boot.nix
        ../nix/modules/limine-install.nix
        ../nix/modules/network.nix
        ../nix/modules/searxng.nix
        ../nix/modules/agentmem.nix
        ../nix/modules/virtualisation.nix
        ../nix/modules/users.nix
        ../nix/modules/hardening.nix
        ../nix/modules/maintenance.nix
        ../nix/modules/desktop.nix
        ../nix/modules/form-factor.nix
        ../nix/modules/steam.nix
        ../nix/hosts.nix
      ];
    };
in
{
  tokyonight = mkTokyonight settings;
  # Lean by default: the flake rides on the ISO, packages come from the
  # binary cache during install. live-iso-full embeds the prebuilt system
  # closure for offline installs (much bigger image).
  live-iso = mkIso false;
  live-iso-full = mkIso true;
  # Exposed for tests/default.nix to build a test-settings closure. NOT a
  # nixosSystem — stripped from nixosConfigurations in flake.nix.
  inherit mkTokyonight;
}
