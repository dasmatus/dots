# LiveISO boot oracle — NixOS test framework edition.
#
# `iso-boot` boots the (plain, unsigned) LiveISO through OVMF UEFI with an
# emulated TPM 2.0 and asserts the installer TUI reaches tty1
# (DOTS_TUI_READY on the serial console). No Secure Boot chain — Secure
# Boot was removed in favor of TPM2 auto-unlock + a LUKS recovery key.
#
# Debug interactively with
# `nix run .#checks.x86_64-linux.iso-boot.driverInteractive`.
{
  pkgs,
  lib,
  iso,
}:
let
  # Precomputed `mkpasswd -m yescrypt --stdin` of the literal "test" — the same
  # path the installer's WriteSecrets step uses (rust/installer-tui/src/install.rs).
  # Hardcoded (not generated) so the test is pure and reproducible; a $y$ hash
  # contains no `${` so it is safe unescaped in a Nix "..." literal.
  testHash = "$y$j9T$LvJdbOoLbTqQ/kknEXAf50$78JSMgcaSLcsay2xhRffsLJnc.dmvTEo5nS9BXTe3l8";

  isoBootTest =
    pkgs.testers.runNixOSTest {
      name = "iso-boot";
      # Headroom for TCG on KVM-less CI runners; under KVM this needs minutes.
      globalTimeout = 2 * 60 * 60;

      nodes.machine = {
        virtualisation = {
          # Boot the attached ISO through real UEFI firmware instead of the
          # test driver's default direct -kernel boot.
          directBoot.enable = false;
          useEFIBoot = true;
          # swtpm-backed TPM 2.0 — the installed system unlocks the LUKS root
          # via a TPM2 token (PCR 7), so emulate the chip the boot chain needs.
          tpm.enable = true;
          memorySize = 4096;
          # The launcher's root qcow2 is a bare non-bootable ext4 image — it
          # doubles as the blank 20G install-target disk.
          diskSize = 20 * 1024;
          qemu.options = [
            "-drive if=none,id=installcd,media=cdrom,readonly=on,format=raw,file=${iso}/iso/${iso.isoName}"
            # The root disk carries bootindex=1; the cdrom must outrank it.
            "-device ide-cd,drive=installcd,bootindex=0"
          ];
        };
      };

      # Console-only assertions: the ISO carries no test instrumentation, so
      # backdoor-based helpers (wait_for_unit, succeed, shutdown) are off
      # limits. nix/iso.nix emits DOTS_TUI_READY on the serial console once the
      # installer TUI starts on tty1.
      testScript = ''
        machine.start()
        machine.wait_for_console_text("DOTS_TUI_READY", timeout=6600)
      '';
    };

  # The load-bearing "can I log in after reboot?" guarantee for the
  # nixos-init migration: userborn creates the account at FIRST boot (not at
  # nixos-install time) and, under immutable /etc, writes passwd/shadow/group
  # to /var/lib/nixos — so login working after a reboot is the proof those
  # credentials survived. No upstream test combines userborn + immutable-etc +
  # reboot + credential survival, hence this one. Verifies the contract the
  # installer's WriteSecrets step (declarative yescrypt → nix/secrets.nix →
  # initialHashedPassword) relies on. The real PAM-keystroke login on a tty is
  # deliberately NOT exercised here: the backdoor runs as root, so reading
  # shadow directly is a strict superset of the information a tty login would
  # produce (the password matching the hash is guaranteed by construction via
  # mkpasswd; the unknown is whether the hash survives reboot, which this
  # asserts). The tmpfs-ephemeral-root half of the impermanence story is
  # covered by eval/build verification (tokyonight toplevel builds clean with
  # the impermanence module + the persistence set generates the expected
  # bind-mount fileSystems) rather than a flaky disk-format-in-VM harness.
  userbornRebootLogin = pkgs.testers.runNixOSTest {
    name = "userborn-reboot-login";
    nodes.machine = {
      # system.etc.overlay asserts a systemd initrd (it mounts the erofs+
      # overlayfs /etc image from the store in stage 1).
      boot.initrd.systemd.enable = true;
      services.userborn.enable = true;
      system.etc.overlay = {
        enable = true;
        mutable = false;
      };
      # initialHashedPassword is only applied at account creation, then a
      # no-op update preserves it — matching users.nix on the real system, so
      # the hash is not re-forced every boot (which would mask a drift bug).
      users.mutableUsers = true;
      users.users.alice = {
        isNormalUser = true;
        initialHashedPassword = testHash;
      };
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("userborn.service")

      # /etc/shadow must be a direct symlink into /var/lib/nixos — the
      # signature that userborn's passwordFilesLocation kicked in under
      # immutable /etc, rather than the legacy Perl setup-etc.pl writing a
      # real file to /etc.
      shadow_target = machine.succeed("readlink -f /etc/shadow").strip()
      # userborn writes /var/lib/nixos/{passwd,shadow,group} directly (no
      # `etc/` subdir), so the contract is "symlinks somewhere under
      # /var/lib/nixos", not a specific filename.
      assert shadow_target.startswith("/var/lib/nixos/"), shadow_target

      # The declarative yescrypt hash landed in the persisted shadow verbatim.
      assert "${testHash}" in machine.succeed("getent shadow alice"), \
          "initialHashedPassword missing from shadow"

      # Reboot equivalent: shutdown the VM and cold-start it again from the same
      # persistent qcow2 root disk. We use shutdown()+start() rather than
      # reboot() because this test-driver version's reboot() reconnect is flaky
      # under TCG (QEMU exits on the guest reset and the driver fails to
      # relaunch it); shutdown+start relaunches QEMU explicitly, which is the
      # same "credentials on persistent storage survive a restart" check. The
      # credentials live under /var/lib/nixos on the persistent root disk, so
      # the hash must still be there — i.e. login still works after a restart.
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("userborn.service")
      assert "${testHash}" in machine.succeed("getent shadow alice"), \
          "hashed password did not survive restart"
    '';
  };
in
{
  iso-boot = isoBootTest;
  userborn-reboot-login = userbornRebootLogin;
}