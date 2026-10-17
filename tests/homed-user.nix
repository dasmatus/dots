# The "test" login account for VM tests built from tokyonightModules.
#
# The login account is a systemd-homed record (nix/modules/system/homed.nix),
# so `users.users.test` no longer creates anyone. This module hands the VM the
# same `home.create.test` credential the installer writes, over QEMU's
# fw_cfg instead of /etc/credstore; systemd-homed-firstboot imports system
# credentials the same way. With a person on the machine, homectl's rescue
# wizard stays quiet and boot does not wait on the console.
#
# homed only activates a home area after authenticating, and greetd's
# `initial_session` autologin never asks for a password. dots-test-home
# activates the home once, with the test password, before any session can
# start; logins then find it active. Production logs in through regreet with
# a password and needs none of this.
{ testHash }:
{ config, ... }:
{
  virtualisation.credentials."home.create.test".text = builtins.toJSON {
    userName = "test";
    uid = 1000;
    # The VM's /home is not btrfs, so no "subvolume" as in production.
    storage = "directory";
    shell = "/run/current-system/sw/bin/fish";
    memberOf = [
      "wheel"
      "audio"
      "video"
      "input"
      "networkmanager"
    ];
    enforcePasswordPolicy = false;
    privileged.hashedPassword = [ testHash ];
    secret.password = [ "test" ];
  };

  systemd.services.dots-test-home = {
    description = "Activate the test user's home area";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-homed-firstboot.service" ];
    before = [
      "systemd-user-sessions.service"
      "linger-users.service"
    ];
    environment.PASSWORD = "test";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.systemd.package}/bin/homectl activate test";
    };
  };
}
