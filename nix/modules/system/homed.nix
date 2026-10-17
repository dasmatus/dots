# The login account is a systemd-homed record, not a users.users entry, and
# system users come from systemd-sysusers. This is how LosOS Desktop
# (github.com/losos-project/losos-desktop, nixos/modules/accounts.nix) does
# accounts, adapted to a machine that already has a user and a TPM-unlocked
# LUKS root.
#
# Why homed: the account travels with its home area. The record (name, uid,
# groups, shell, password hash) is signed by this machine's homed key and
# stored next to the home, so nothing about the person lives in /etc, which
# impermanence wipes every boot anyway. sysusers then only has system users
# to create, which is all it can do: it refuses normal users outright.
#
# Storage is whatever the record asks for. The installer writes
# `"storage": "subvolume"`: /home is already btrfs on the LUKS root
# (nix/system/disko.nix), so a second LUKS layer per user would cost a
# password-only unlock (no FIDO2 login, see desktop/common.nix) for no gain
# in what is encrypted at rest.
#
# How the account comes to exist, in order of preference:
#   1. A `home.create.<user>` credential in /etc/credstore, written by the
#      installer (rust/installer-tui, the Quickshell installer) or by
#      scripts/homed-migrate.sh on an existing install. systemd-homed-firstboot
#      imports it (ImportCredential=home.*), creates the user, and the
#      credential is deleted once the user exists.
#   2. homectl's own console wizard, on tty1, if no regular user exists and no
#      credential produced one. It is the rescue path: there is no root
#      password, so without an account nobody can log in to fix anything.
#
# Migrating a userborn install: the old /home/<user> is a plain directory
# owned by uid 1000. The migration credential asks for uid 1000 too, so the
# files need no chown; dots-homed-migrate moves the old directory aside before
# homed creates the account, and dots-homed-migrate-data copies it into the
# new home area (reflinks on btrfs, so no second copy of the data). The old
# directory stays as /home/<user>.pre-homed until it is deleted by hand.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.dots.homed) user;
  systemd = config.systemd.package;
  credential = "/etc/credstore/home.create.${user}";
  home = "/home/${user}";
  preHomed = "${home}.pre-homed";
  homeDir = "${home}.homedir";
  marker = "${preHomed}/.dots-homed-migrated";
in
{
  options.dots.homed.user = lib.mkOption {
    type = lib.types.str;
    description = "The login account homed holds the record for.";
  };

  config = {
    systemd.sysusers.enable = true;
    # Nothing a person changes is in /etc/passwd any more: system users are
    # regenerated from the config, the login account is homed's.
    users.mutableUsers = false;

    # NixOS refuses a configuration in which neither root nor a wheel user in
    # users.users can log in. The administrator is a homed user the module
    # system never sees, so that check cannot pass and is turned off; root
    # stays locked.
    users.allowNoPasswordLogin = true;

    services.homed.enable = true;

    # Nix's build users start at uid 30001, which userdb counts as regular
    # users. homectl firstboot would then believe a person already exists and
    # never offer its rescue wizard. With auto-allocated uids the daemon takes
    # build uids from a range of its own and NixOS creates no nixbld users.
    nix.settings = lib.mkIf config.nix.enable {
      auto-allocate-uids = true;
      experimental-features = [ "auto-allocate-uids" ];
    };

    systemd.services.systemd-homed-firstboot = {
      # Every boot, not only systemd's first. The machine id is not persisted
      # (impermanence.nix), which makes every boot a first boot already, but
      # that is an accident of the persistence set; the credential and the
      # rescue wizard must not depend on it. An empty Condition resets the
      # unit's only one, ConditionFirstBoot=. With a regular user present the
      # wizard does nothing.
      unitConfig.ConditionFirstBoot = "";
      # homectl firstboot exits 0 even when creating from a credential fails,
      # so the credential is only removed once the account demonstrably
      # exists. A failed attempt keeps it for the next boot.
      serviceConfig.ExecStartPost = toString (
        pkgs.writeShellScript "dots-homed-drop-credential" ''
          if ${systemd}/bin/userdbctl user ${lib.escapeShellArg user} >/dev/null 2>&1; then
            rm -f ${lib.escapeShellArg credential}
          fi
        ''
      );
    };

    systemd.services.dots-homed-migrate = {
      description = "Move ${user}'s pre-homed home directory aside";
      wantedBy = [ "systemd-homed.service" ];
      before = [ "systemd-homed-firstboot.service" ];
      after = [ "home.mount" ];
      unitConfig = {
        # Only a plain directory, only with no homed area yet, and only when a
        # credential is waiting to create one. Without the credential nothing
        # would take the directory's place.
        ConditionPathIsDirectory = home;
        ConditionPathIsMountPoint = "!${home}";
        ConditionPathExists = [
          "!${homeDir}"
          "!${preHomed}"
          credential
        ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/mv -T ${home} ${preHomed}";
      };
    };

    systemd.services.dots-homed-migrate-data = {
      description = "Copy ${user}'s pre-homed files into the homed home area";
      wantedBy = [ "systemd-homed.service" ];
      after = [ "systemd-homed-firstboot.service" ];
      before = [ "systemd-user-sessions.service" ];
      unitConfig = {
        ConditionPathIsDirectory = [
          preHomed
          homeDir
        ];
        ConditionPathExists = "!${marker}";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The home area is inactive here (no session can start before
        # systemd-user-sessions), so its directory on disk is written
        # directly. Ownership is kept as is: the record carries the uid the
        # files already have.
        ExecStart = toString (
          pkgs.writeShellScript "dots-homed-migrate-data" ''
            set -eu
            ${pkgs.coreutils}/bin/cp -a --reflink=auto ${preHomed}/. ${homeDir}/
            ${pkgs.coreutils}/bin/touch ${marker}
          ''
        );
      };
    };
  };
}
