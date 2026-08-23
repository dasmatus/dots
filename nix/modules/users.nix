# The primary user — replaces the retired Gentoo first-boot "homectl create"
# flow (git history); the username comes from nix/settings.nix (written by
# the installer TUI).
# mutableUsers stays true so passwords seeded once by the installer survive
# rebuilds (userborn preserves existing hashes; see below).
{
  config,
  pkgs,
  settings,
  inputs,
  aipageFirefox,
  aipageChrome,
  wallpaperTui,
  hyprmon,
  settingsMenu,
  beamenuPkg,
  beamenuCanvasPkg,
  beamenuCalcPkg,
  beamenuStatusPkg,
  claudeDesktop,
  ...
}:
let
  # Optional install-time user password hash, written by the installer TUI
  # into nix/secrets.nix (gitignored) in the STAGED_FLAKE only — NOT stashed
  # to /var/lib/dots, so dots-clone never restores it into the user's git
  # clone (nix/home/dots-repo.nix only copies settings.nix + facter.json). At
  # install time the file exists and userborn creates the account with this
  # hash on first boot; on rebuild from the clean user clone the file is
  # absent, the hash is null, and userborn leaves the existing /var/lib/nixos
  # shadow entry alone (mutableUsers=true → update(None) is a no-op in
  # userborn's shadow::Entry::update). Only the user account is seeded —
  # root is intentionally left locked (no initialHashedPassword), so the
  # only login is the wheel user via sudo; `nixos-install --no-root-passwd`
  # keeps the root password unset during install.
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
  # Users are created at FIRST BOOT by the userborn unit, not during
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
  # Pin the credential file location to /var/lib/nixos REGARDLESS of /etc
  # mutability. userborn's default is
  # `if immutableEtc && !static then "/var/lib/nixos" else "/etc"` (nixpkgs:
  # nixos/modules/services/system/userborn.nix), so it only lands on the
  # persisted /var/lib/nixos (impermanence.nix bind-mounts it from /persist)
  # when /etc is immutable. core.nix sets `system.etc.overlay.mutable = true`
  # so NetworkManager can write /etc/NetworkManager/system-connections (see
  # memory: etc-overlay-mutable-required-for-bindmounts) — but that flips the
  # userborn default to /etc, whose overlay upperdir (/.rw-etc/upper) lives on
  # the tmpfs root that impermanence wipes each boot and that is NOT in the
  # persistence set. Credential files there vanish on reboot → locked out
  # ("can't log in after reboot"). The option's own description covers this
  # case ("this can also serve other use cases, e.g. when `/etc` is on a
  # `tmpfs`"), so pin it explicitly: /etc stays writable for NM, while
  # passwd/shadow/group stay on the persisted /var/lib/nixos and /etc just
  # holds userborn's symlinks into it. No assertion fires — userborn only
  # forbids passwordFilesLocation == "/etc" when /etc is immutable, which it
  # no longer is. Guarded by the userborn-reboot-login VM test.
  services.userborn.passwordFilesLocation = "/var/lib/nixos";
  users.users.${config.dots.username} = {
    isNormalUser = true;
    # Pretty name (GECOS full-name field) — reuse the git identity so the
    # login screen and `getent passwd` show the same name as `git user.name`.
    description = config.dots.gitName;
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
    # desktop block in nix/modules/desktop.nix reads it. `dots` is the typed
    # projection of the installer answers (nix/modules/dots.nix) so the HM-side
    # AI gating (nix/home/{claude,codex}.nix) and the dots-clone symlinks
    # (nix/home/dots-repo.nix) read the same values as the system modules.
    extraSpecialArgs = {
      inherit
        inputs
        settings
        aipageFirefox
        aipageChrome
        wallpaperTui
        hyprmon
        settingsMenu
        beamenuPkg
        beamenuCanvasPkg
        beamenuCalcPkg
        beamenuStatusPkg
        claudeDesktop
        ;
      dots = config.dots;
    };
    sharedModules = [ inputs.nixvim.homeModules.nixvim ];
    users.${config.dots.username} = import ../home;
  };
}
