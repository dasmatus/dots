# homed-accounts: the login account as a systemd-homed record
# (nix/modules/system/homed.nix), checked on the two paths that create it.
#
#   fresh     — first a machine with nobody on it, which must stop at
#               homectl's console wizard; then what the installer leaves
#               behind: a `home.create.<user>` credential and no home at
#               all. The next boot must create the account with uid 1000
#               and its groups, drop the credential, and still know the
#               account after a restart.
#   migrated  — an existing userborn install: a plain /home/<user> owned by
#               uid 1000 plus the credential scripts/homed-migrate.sh writes.
#               The next boot must move the old directory aside, create the
#               account, copy the files in, and let a real password login on
#               a tty see them.
#
# Both nodes mirror production where it matters: systemd initrd, nixos-init,
# a mutable /etc overlay, and /etc/credstore bind-mounted from persistent
# storage the way impermanence.nix does it. Records are created with
# "directory" storage, since the VM's /home is ext4; production asks for
# "subvolume" on btrfs, which homed treats the same way above the filesystem.
#
# Restarts are shutdown()+start(), not reboot(), for the reason the old
# userborn-reboot-login test recorded: reboot() is flaky under TCG.
{
  pkgs,
  testHash,
}:
let
  record = storage: {
    userName = "alice";
    uid = 1000;
    inherit storage;
    shell = "/run/current-system/sw/bin/bash";
    memberOf = [
      "wheel"
      "audio"
    ];
    enforcePasswordPolicy = false;
    privileged.hashedPassword = [ testHash ];
    secret.password = [ "test" ];
  };

  node = {
    imports = [ ../nix/modules/system/homed.nix ];
    dots.homed.user = "alice";
    boot.initrd.systemd.enable = true;
    system.nixos-init.enable = true;
    system.etc.overlay = {
      enable = true;
      mutable = true;
    };
    # impermanence.nix bind-mounts /persist/etc/credstore here; the VM's root
    # disk is persistent already, so a bind from /var stands in for /persist.
    systemd.tmpfiles.rules = [ "d /var/lib/credstore 0700 root root -" ];
    fileSystems."/etc/credstore" = {
      device = "/var/lib/credstore";
      options = [ "bind" ];
      depends = [ "/var" ];
    };
    environment.systemPackages = [ pkgs.jq ];
  };

  credentialJson = pkgs.writeText "home.create.alice" (builtins.toJSON (record "directory"));
in
pkgs.testers.runNixOSTest {
  name = "homed-accounts";

  nodes.fresh = node;
  nodes.migrated = node;

  testScript = ''
    def plant_credential(m):
        m.succeed("install -m 0600 ${credentialJson} /etc/credstore/home.create.alice")

    def assert_account(m):
        m.succeed("userdbctl user alice")
        assert m.succeed("id -u alice").strip() == "1000"
        groups = m.succeed("id -nG alice").split()
        assert "wheel" in groups and "audio" in groups, groups
        m.succeed("test ! -e /etc/credstore/home.create.alice")
        m.succeed("systemctl is-active systemd-homed.service")
        assert m.succeed("systemctl --failed --no-legend").strip() == ""

    with subtest("fresh install: the installer's credential creates the account"):
        fresh.start()
        # No credential on this boot and no person yet, so homectl's rescue
        # wizard asks on /dev/console (tty1 here, the last console= on the
        # kernel command line), and boot waits for it. Seeing the prompt
        # proves Nix's build users no longer count as people
        # (auto-allocate-uids in homed.nix); an empty answer skips it.
        fresh.wait_until_tty_matches("1", "Please enter user name to create")
        fresh.send_key("ret")
        fresh.wait_for_unit("multi-user.target")
        fresh.fail("userdbctl user alice")
        plant_credential(fresh)
        fresh.shutdown()
        fresh.start()
        fresh.wait_for_unit("systemd-homed-firstboot.service")
        assert_account(fresh)
        fresh.succeed("printf 'test\\n' | PASSWORD=test homectl authenticate alice")

    with subtest("fresh install: the account survives a restart"):
        fresh.shutdown()
        fresh.start()
        fresh.wait_for_unit("systemd-homed.service")
        assert_account(fresh)

    with subtest("migration: a userborn home is moved, recreated and filled"):
        migrated.start()
        # The userborn account is gone with the switch, so this boot also
        # finds nobody and asks; skipped, as on the fresh node.
        migrated.wait_until_tty_matches("1", "Please enter user name to create")
        migrated.send_key("ret")
        migrated.wait_for_unit("multi-user.target")
        migrated.succeed(
            "mkdir -p /home/alice/docs",
            "echo kept > /home/alice/docs/note",
            "chown -R 1000:1000 /home/alice",
            "chmod 0700 /home/alice",
        )
        plant_credential(migrated)
        migrated.shutdown()
        migrated.start()
        migrated.wait_for_unit("dots-homed-migrate-data.service")
        assert_account(migrated)
        migrated.succeed("test -f /home/alice.pre-homed/.dots-homed-migrated")
        migrated.succeed("test -d /home/alice.homedir")

    with subtest("migration: a password login on a tty sees the old files"):
        migrated.wait_until_tty_matches("1", "login: ")
        migrated.send_chars("alice\n")
        migrated.wait_until_tty_matches("1", "Password: ")
        migrated.send_chars("test\n")
        migrated.wait_until_succeeds("pgrep -u alice bash")
        state = migrated.succeed("homectl inspect --json=short alice | jq -r .status.state").strip()
        assert state == "active", state
        assert migrated.succeed("cat /home/alice/docs/note").strip() == "kept"
        assert migrated.succeed("stat -c %u /home/alice/docs/note").strip() == "1000"
  '';
}
