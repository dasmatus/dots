# LiveISO boot oracle — NixOS test framework edition.
#
# Two checks, both bootable as `nix build .#checks.x86_64-linux.<name>`:
#   iso-boot        the unsigned LiveISO boots through plain OVMF UEFI with an
#                   emulated TPM 2.0 and the installer TUI reaches tty1
#                   (DOTS_TUI_READY on the serial console).
#   iso-secureboot  the Secure Boot-signed ISO boots under ENFORCING OVMF —
#                   Microsoft certs validate the Fedora shim, the ISO's own
#                   MOK cert (pre-enrolled in db) validates GRUB — and the
#                   guest reports DOTS_SECUREBOOT=1.
#
# Fixtures are pure derivations: signing runs scripts/sign-iso.sh inside the
# build sandbox with an ephemeral MOK key, NVRAM enrollment replays the same
# virt-fw-vars invocation the retired bash harness used. Debug interactively
# with `nix run .#checks.x86_64-linux.<name>.driverInteractive`.
{
  pkgs,
  lib,
  iso,
  shim-signed,
  signScript,
  sbToolPackages,
}:
let
  # Owner GUID recorded next to the enrolled db cert (cosmetic but stable).
  sbOwnerGuid = "ce690aa3-f1e6-4a12-a8f3-8ea7add16fda";

  # Precomputed `mkpasswd -m yescrypt --stdin` of the literal "test" — the same
  # path the installer's WriteSecrets step uses (rust/installer-tui/src/install.rs).
  # Hardcoded (not generated) so the test is pure and reproducible; a $y$ hash
  # contains no `${` so it is safe unescaped in a Nix "..." literal.
  testHash = "$y$j9T$LvJdbOoLbTqQ/kknEXAf50$78JSMgcaSLcsay2xhRffsLJnc.dmvTEo5nS9BXTe3l8";

  # Secure Boot-sign the ISO via scripts/sign-iso.sh — the single source of
  # signing truth. `-k mok` triggers the script's keygen path: an EPHEMERAL
  # MOK keypair born and discarded with the sandbox, so this derivation is
  # deliberately not bit-reproducible; production signing keeps using the
  # persistent secrets/secureboot/ key outside the sandbox. The script stages
  # its output at ${OUT}.tmp, and a sibling of $out in /nix/store is not
  # writable in the sandbox — hence sign to the build dir, then mv.
  signedIso =
    pkgs.runCommand "tokyonight-dots-installer-signed.iso"
      {
        nativeBuildInputs = sbToolPackages;
      }
      ''
        bash ${signScript} -k mok --shim ${shim-signed} -o signed.iso \
          ${iso}/iso/${iso.isoName}
        mv signed.iso $out
      '';

  # Enforcing-Secure-Boot NVRAM template: Microsoft certs (validate the shim)
  # plus the MOK cert extracted from the signed ISO itself — which also proves
  # the ISO ships its cert at the documented enrollment path.
  enrolledVars =
    pkgs.runCommand "ovmf-vars-sb-enrolled.fd"
      {
        nativeBuildInputs = [
          pkgs.xorriso
          pkgs.python3Packages.virt-firmware
        ];
      }
      ''
        xorriso -osirrox on -indev ${signedIso} \
          -extract /EFI/BOOT/tokyonight-dots-mok.cer mok.cer
        virt-fw-vars --input ${pkgs.OVMFFull.fd.variables} --output $out \
          --enroll-redhat --secure-boot \
          --add-db ${sbOwnerGuid} mok.cer
      '';

  mkIsoBootTest =
    {
      name,
      isoFile,
      secureBoot,
    }:
    pkgs.testers.runNixOSTest {
      inherit name;
      # Headroom for TCG on KVM-less CI runners; under KVM this needs minutes.
      globalTimeout = 2 * 60 * 60;

      nodes.machine = {
        virtualisation = {
          # Boot the attached ISO through real UEFI firmware instead of the
          # test driver's default direct -kernel boot.
          directBoot.enable = false;
          useEFIBoot = true;
          # swtpm-backed TPM 2.0, parity with the old libvirt harness.
          tpm.enable = true;
          memorySize = 4096;
          cores = 4;
          # The launcher's root qcow2 is a bare non-bootable ext4 image — it
          # doubles as the blank 20G install-target disk.
          diskSize = 20 * 1024;
          qemu.options = [
            "-drive if=none,id=installcd,media=cdrom,readonly=on,format=raw,file=${isoFile}"
            # The root disk carries bootindex=1; the cdrom must outrank it.
            "-device ide-cd,drive=installcd,bootindex=0"
          ];
        }
        // lib.optionalAttrs secureBoot {
          useSecureBoot = true;
          # secureBoot+tpmSupport OVMF build; its SMM requirement flips the
          # machine to q35 with enforcing pflash.
          efi.OVMF = pkgs.OVMFFull.fd;
          # The launcher copies this template as the VM's writable NVRAM —
          # the in-Nix replacement for the old virt-fw-vars seed file.
          efi.variables = "${enrolledVars}";
        };
      };

      # Console-only assertions: the ISO carries no test instrumentation, so
      # backdoor-based helpers (wait_for_unit, succeed, shutdown) are off
      # limits. Marker order is guaranteed by ExecStartPre order in
      # nix/iso.nix — DOTS_TUI_READY is emitted before DOTS_SECUREBOOT=…, so
      # these sequential waits must stay in that order.
      testScript = ''
        machine.start()
        machine.wait_for_console_text("DOTS_TUI_READY", timeout=6600)
      ''
      + lib.optionalString secureBoot ''
        machine.wait_for_console_text("DOTS_SECUREBOOT=1", timeout=600)
      '';
    };
in
{
  iso-boot = mkIsoBootTest {
    name = "iso-boot";
    isoFile = "${iso}/iso/${iso.isoName}";
    secureBoot = false;
  };
  iso-secureboot = mkIsoBootTest {
    name = "iso-secureboot";
    isoFile = "${signedIso}";
    secureBoot = true;
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
  userborn-reboot-login = pkgs.testers.runNixOSTest {
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
}
