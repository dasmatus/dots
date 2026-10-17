# The primary user. The account itself is a systemd-homed record
# (nix/modules/system/homed.nix): the username comes from nix/data/settings.nix
# (written by the installer), and the record, password included, is created on
# first boot from the credential the installer leaves in /etc/credstore.
#
# What is left here is the half NixOS still has to know about: the
# users.users entry home-manager reads the home directory and per-user
# profile from, and home-manager itself.
{
  config,
  lib,
  pkgs,
  settings,
  inputs,
  aipageFirefox,
  aipageChrome,
  settingsMenu,
  claudeDesktop,
  betterbird,
  chromaleon,
  ...
}:
{
  imports = [ ./homed.nix ];

  environment.pathsToLink = [
    "/share/applications"
    "/share/xdg-desktop-portal"
  ];

  dots.homed.user = config.dots.username;

  # `enable = false`: no passwd entry, no groups, nothing for sysusers to
  # create, and sysusers would refuse a normal user anyway. The entry stays
  # because home-manager's NixOS module takes the home directory from it and
  # puts the user's packages in /etc/profiles/per-user/<name> through its
  # `packages`, which NixOS builds whether or not the account is enabled.
  #
  # Groups (wheel, audio, video, input, networkmanager, and libvirtd when the
  # VM stack is on) are the record's `memberOf`, set by whoever created it;
  # `homectl update <user> --member-of=...` changes them. The shell is the
  # record's too; it stays named here because NixOS checks that the shell's
  # program is enabled.
  #
  # GECOS is the login name rather than the git identity: that is an agenix
  # secret resolved at activation (nix/home/secrets/identity.nix), and a full
  # name in a world-readable record would un-hide it.
  users.users.${config.dots.username} = {
    enable = false;
    isNormalUser = true;
    home = "/home/${config.dots.username}";
    description = config.dots.username;
    shell = pkgs.fish;
  };

  home-manager = {
    # Activate at login, as a user unit, rather than from a system unit at
    # boot: the home area only exists while homed has it active, which is
    # from login until the last session ends.
    startAsUserService = true;
    useGlobalPkgs = true;
    useUserPackages = true;
    # home modules need flake inputs too (nixvim module, haumea lib), plus
    # the in-flake aipage dists consumed by nix/home/{librewolf,brave}.nix
    # and the in-flake packages consumed across nix/home.
    # `settings` is passed for the eval-time identity keys
    # (nix/home/proton/proton.nix's protonEmail/protonRealName,
    # nix/home/apps/bitwarden.nix's bitwardenEmail) — the git identity is NOT
    # among them any more, it is an agenix secret resolved at activation
    # (nix/home/secrets/identity.nix). The desktop choice in settings.desktop
    # is gated on the HM side through nix/home/profiles/session.nix, which
    # dispatches to the matching per-DE home module. `dots` is the typed
    # projection of the installer answers (nix/modules/dots.nix) so the HM-side
    # AI gating (nix/home/{claude,codex}.nix) and the dots-clone symlinks
    # (nix/home/base/dots-repo.nix) read the same values as the system modules.
    extraSpecialArgs = {
      inherit
        inputs
        settings
        aipageFirefox
        aipageChrome
        settingsMenu
        claudeDesktop
        betterbird
        chromaleon
        ;
      dots = config.dots;
    };
    # agenix's home-manager module is required by nix/home/secrets/identity.nix,
    # which nix/home/profiles/portable.nix imports — so it is needed on BOTH
    # entry points into that profile. flake/home.nix adds it to its own module
    # list for the standalone build; this is the NixOS half of the same
    # requirement.
    sharedModules = [
      inputs.nixvim.homeModules.nixvim
      inputs.agenix.homeManagerModules.default
      # Declarative Flatpak (nix/home/base/flatpaks.nix). The home-manager
      # module drives the USER flatpak installation, so this stays on the HM
      # side even on NixOS rather than becoming a system service.
      inputs.nix-flatpak.homeManagerModules.nix-flatpak
    ];
    users.${config.dots.username} = import ../../home;
  };
}
