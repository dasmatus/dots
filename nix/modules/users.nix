# The primary user — replaces the retired Gentoo first-boot "homectl create"
# flow (git history); the username comes from nix/settings.nix (written by
# the installer TUI).
# mutableUsers stays true so passwords seeded once by the installer survive
# rebuilds (userborn preserves existing hashes; see below).
{
  pkgs,
  settings,
  inputs,
  aipageFirefox,
  aipageChrome,
  wallpaperTui,
  hyprmon,
  ...
}:
let
  # Optional install-time password hashes, written by the installer TUI into
  # nix/secrets.nix (gitignored) in the STAGED_FLAKE only — NOT stashed to
  # /var/lib/dots, so dots-clone never restores it into the user's git clone
  # (nix/home/dots-repo.nix only copies settings.nix + facter.json). At install
  # time the file exists and userborn creates the accounts with these hashes
  # on first boot; on rebuild from the clean user clone the file is absent,
  # both hashes are null, and userborn leaves the existing /var/lib/nixos
  # shadow entries alone (mutableUsers=true → update(None) is a no-op in
  # userborn's shadow::Entry::update).
  # `initialHashedPassword` (not `hashedPassword`): userborn applies it ONLY at
  # account creation (HashedPassword::Initial), then never overwrites it — so
  # a later `passwd` change survives reboot/rebuild, matching mutableUsers.
  secretsFile = ../secrets.nix;
  secrets = if builtins.pathExists secretsFile then import secretsFile else { };
in
{
  environment.pathsToLink = [
    "/share/applications"
    "/share/xdg-desktop-portal"
  ];
  users.mutableUsers = true;
  # Userborn replaces NixOS's legacy Perl `update-users-groups.pl` activation
  # script with a systemd service (systemd-sysusers.service alias). It is one
  # of the two prerequisites `system.nixos-init` (nix/modules/core.nix)
  # asserts — nixos-init is bashless and ships no activation scripts, so user
  # management has to run as a unit. The NixOS users-groups module gates
  # `system.activationScripts.users` to `""` when this is on (nixpkgs:
  # nixos/modules/config/users-groups.nix), so userborn's own
  # `activationScripts.users == ""` assertion holds for free.
  #
  # /etc is mounted immutable (system.etc.overlay.mutable = false, core.nix),
  # so userborn can't write passwd/shadow/group there: `passwordFilesLocation`
  # defaults to `/var/lib/nixos` and /etc just holds direct-symlinks into it.
  # Users are therefore created at FIRST BOOT by the userborn unit, not during
  # nixos-install's activation — so the old `nixos-enter -- chpasswd` install
  # step (which targeted a user that didn't exist yet) is replaced by the
  # declarative `initialHashedPassword` below, seeded via nix/secrets.nix.
  #
  # `mutableUsers = true` is kept: userborn runs with
  # USERBORN_MUTABLE_USERS=true and only disables/drains users that dropped
  # out of the config — existing password hashes in /var/lib/nixos are left
  # intact (shadow::Entry::update(None) is a no-op), so the installer-seeded
  # passwords survive rebuilds as before.
  services.userborn.enable = true;
  users.users.root.initialHashedPassword = secrets.rootHash or null;
  users.users.${settings.username} = {
    isNormalUser = true;
    shell = pkgs.fish;
    initialHashedPassword = secrets.userHash or null;
    extraGroups = [
      "wheel"
      "audio"
      "video"
      "input"
      "networkmanager"
      "libvirtd"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # home modules need flake inputs too (nixvim module, haumea lib), plus
    # the in-flake aipage dists consumed by nix/home/{librewolf,brave}.nix
    # and the in-flake packages consumed across nix/home.
    # `settings` is passed so nix/home/git.nix can read the installer-collected
    # git identity (settings.gitName / settings.gitEmail); the desktop choice
    # in settings.desktop is NOT gated on the HM side — only the system-level
    # desktop block in nix/modules/desktop.nix reads it.
    extraSpecialArgs = {
      inherit
        inputs
        settings
        aipageFirefox
        aipageChrome
        wallpaperTui
        hyprmon
        ;
    };
    sharedModules = [ inputs.nixvim.homeModules.nixvim ];
    users.${settings.username} = import ../home;
  };
}
