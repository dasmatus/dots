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
  # The disk-and-boot-chain half of tokyonight's module list: everything
  # disko.nix and impermanence.nix touch, plus the bootloader module that
  # only makes sense on top of a real disk (Limine + the TPM2-bound LUKS
  # unlock enrolled against it). Kept apart from `tokyonightModules` below
  # so tests/session-boot.nix can take the OTHER half — the desktop/
  # hardening/services stack — without dragging in a disk layout no test VM
  # has. See that file's header for why extendModules over the full
  # `nixosConfigurations.tokyonight` was tried and rejected instead.
  tokyonightDiskModules =
    s:
    [
      inputs.disko.nixosModules.disko
      inputs.impermanence.nixosModules.impermanence
      (import ../nix/system/disko.nix { inherit (s) disks swapSize; })
      ../nix/modules/system/impermanence.nix
      ../nix/modules/system/limine-install.nix
    ];

  # The desktop/hardening/services half — independent of disk layout, so
  # this is also the module list tests/session-boot.nix's boot oracle
  # builds its VM from. Exported here, not hand-copied there, specifically
  # so a module added or removed here changes what that gate covers
  # automatically instead of needing a second, driftable edit (a later
  # phase adding a system module and the gate silently not picking it up
  # was the exact failure mode this split exists to close).
  tokyonightModules = [
    inputs.home-manager.nixosModules.home-manager
    ../nix/modules/dots.nix
    ../nix/modules/system/core.nix
    ../nix/modules/system/kernel.nix
    ../nix/modules/system/boot.nix
    ../nix/modules/system/network.nix
    ../nix/modules/services/searxng.nix
    ../nix/modules/system/virtualisation.nix
    ../nix/modules/system/users.nix
    ../nix/modules/system/hardening.nix
    ../nix/modules/system/apparmor.nix
    ../nix/modules/system/apparmor-store.nix
    ../nix/modules/services/maintenance.nix
    ../nix/modules/desktop/desktop.nix
    ../nix/modules/system/form-factor.nix
    ../nix/modules/desktop/steam.nix
    ../nix/system/hosts.nix
  ];

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
        settingsMenu = inputs.self.packages.x86_64-linux.settings;
        claudeDesktop = inputs.self.packages.x86_64-linux.claude-desktop;
        betterbird = inputs.self.packages.x86_64-linux.betterbird;
        # nix/modules/system/users.nix takes `chromaleon` as a module argument and
        # forwards it into home-manager's extraSpecialArgs for
        # nix/home/base/gnome-extensions.nix. flake/home.nix supplies it on the
        # standalone side; without it here the NixOS eval fails outright with
        # "attribute 'chromaleon' missing", taking `nix flake check` with it.
        chromaleon = inputs.self.packages.x86_64-linux.chromaleon;
      };
      modules = tokyonightDiskModules s ++ tokyonightModules;
    };
in
{
  tokyonight = mkTokyonight settings;
  # Lean by default: the flake rides on the ISO, packages come from the
  # binary cache during install. live-iso-full embeds the prebuilt system
  # closure for offline installs (much bigger image).
  live-iso = mkIso false;
  live-iso-full = mkIso true;
  # Exposed for tests/default.nix: `mkTokyonight` to build a test-settings
  # closure, `tokyonightModules` for the session-boot gate to self-sync
  # against. Neither is a nixosSystem — both stripped from
  # nixosConfigurations in flake.nix.
  inherit mkTokyonight tokyonightModules;
}
