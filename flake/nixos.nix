# nixosConfigurations — the installed `tokyonight` system + the two LiveISO
# closures (lean + full). Hardware is not baked into variants: nix/system/hosts.nix
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
        pgAgentmem = inputs.self.packages.x86_64-linux.pg-agentmem;
        settingsMenu = inputs.self.packages.x86_64-linux.settings;
        # The sandbox CLI. The Settings panel's Security page shells out to
        # `dots-sandbox report --json` and `dots-sandbox policy dump`, so the
        # binary has to be on the session's PATH — packaging it in the flake
        # alone left the page waiting forever on a command that did not exist.
        dotsSandbox = inputs.self.packages.x86_64-linux.dots-sandbox;
        claudeDesktop = inputs.self.packages.x86_64-linux.claude-desktop;
        betterbird = inputs.self.packages.x86_64-linux.betterbird;
      };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.home-manager.nixosModules.home-manager
        inputs.impermanence.nixosModules.impermanence
        (import ../nix/system/disko.nix { inherit (s) disks swapSize; })
        ../nix/modules/dots.nix
        ../nix/modules/system/core.nix
        ../nix/modules/system/impermanence.nix
        ../nix/modules/system/boot.nix
        ../nix/modules/system/limine-install.nix
        ../nix/modules/system/network.nix
        ../nix/modules/services/searxng.nix
        ../nix/modules/services/agentmem.nix
        ../nix/modules/system/virtualisation.nix
        ../nix/modules/system/sandbox-host.nix
        ../nix/modules/system/users.nix
        ../nix/modules/system/hardening.nix
        ../nix/modules/services/maintenance.nix
        ../nix/modules/desktop/desktop.nix
        ../nix/modules/system/form-factor.nix
        ../nix/modules/desktop/steam.nix
        ../nix/system/hosts.nix
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
