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
  mkTokyonight,
  dotsFlake,
  inputs,
}:
let
  # Precomputed `mkpasswd -m yescrypt --stdin` of the literal "test" — the same
  # path the installer's WriteSecrets step uses (rust/installer-tui/src/install.rs).
  # Hardcoded (not generated) so the test is pure and reproducible; a $y$ hash
  # contains no `${` so it is safe unescaped in a Nix "..." literal.
  testHash = "$y$j9T$LvJdbOoLbTqQ/kknEXAf50$78JSMgcaSLcsay2xhRffsLJnc.dmvTEo5nS9BXTe3l8";

  # tokyonight with VM-sized disks/swap so the disko layout fits /dev/vda and
  # the closure can be pre-built. The committed settings.nix has /dev/nvme0n1 +
  # 32G swap, which changes the disko-generated swapDevices/disk entries and
  # therefore the toplevel — see docs/superpowers/specs/
  # 2026-07-28-limine-bootloader-design.md (closure-feasibility note).
  testSettings = (import ../nix/defaults.nix) // {
    username = "test";
    hostname = "test";
    disks = [ "/dev/vda" ];
    swapSize = "1G";
    gitName = "Test User";
    gitEmail = "test@example.com";
  };
  # The tokyonight closure built with test settings. Pre-substituted into the
  # installer VM via mountHostNixStore + extraDependencies so nixos-install
  # needs no network. The staged flake (copied from /etc/dots = flake `self`)
  # carries no nix/secrets.nix (gitignored, absent), so users.nix's
  # `secrets = {}` matches this host build's `secrets = {}` and nixos-install
  # substitutes this closure verbatim.
  testTokyonight = mkTokyonight testSettings;
  testToplevel = testTokyonight.config.system.build.toplevel;
  # Flake input source paths the installer VM needs to evaluate the flake:
  # mountHostNixStore exposes the host store, but only paths listed in
  # extraDependencies are guaranteed pulled into the test build's closure.
  flakeInputPaths = [
    inputs.nixpkgs.outPath
    inputs.home-manager.outPath
    inputs.disko.outPath
    inputs.impermanence.outPath
    inputs.nixvim.outPath
    inputs.haumea.outPath
    inputs.hyprland.outPath
  ];

  # Full install+boot oracle for the Limine switch: runs the installer's plan()
  # (rust/installer-tui/src/install.rs) in a VM, then boots the installed disk
  # via Limine and asserts the TPM2-unlocked LUKS root comes up. Two nodes
  # share the same qcow2 + swtpm state (target.state_dir = installer.state_dir,
  # plus a shared system.name so the swtpm state dir matches) so the TPM2 owner
  # seed persists and the PCR-7-bound token unseals on the target. The dots ISO
  # itself has no test instrumentation (no backdoor shell — iso-boot is
  # console-only by design), so the installer node is a test-instrumented
  # installation-device VM, not the raw ISO; the install steps are identical to
  # install.rs::plan(). Mirrors nixpkgs tests/installer.nix (two-node
  # install+boot, shared diskImage + state_dir) and tests/systemd-initrd-luks-tpm2.nix
  # (OVMFFull + swtpm + PCR-7 enroll → boot → assert mount).
  limineInstallBootTest =
    pkgs.testers.runNixOSTest {
      name = "limine-install-boot";
      # Full closure build + disko + nixos-install + 2x boot under TCG is slow.
      globalTimeout = 4 * 60 * 60;

      nodes =
        let
          # Mirrors nixpkgs installer.nix `commonConfig`: both nodes share the
          # SAME disk file (./target.qcow2) so the installer's /dev/vda becomes
          # the target's boot disk, the same OVMFFull firmware (so PCR 7 is
          # measured identically), and — via the shared state_dir below — the
          # same swtpm. `system.name` is forced equal so the swtpm state dir
          # (`<system.name>-swtpm`, qemu-vm.nix) resolves to the same path under
          # the shared state_dir for both nodes; without this the two nodes get
          # distinct swtpm dirs and the PCR-7 token cannot unseal.
          commonConfig = {
            system.name = "limine-test";
            virtualisation = {
              cores = 8;
              memorySize = 2048;
              # Both installer and target use the same drive (installer.nix:693).
              diskImage = "./target.qcow2";
              # 20G install target — the shared primary disk (installer.nix
              # sizes the install target via diskSize, not emptyDiskImages).
              diskSize = 20 * 1024;
              # Only OVMFFull contains the TCG/TIS module swtpm needs.
              efi.OVMF = pkgs.OVMFFull;
              tpm.enable = true;
            };
          };
        in
        {
          # NOTE: the nixpkgs `installation-device` profile is deliberately NOT
          # imported — it sets nixpkgs.overlays, which runNixOSTest pins
          # read-only (types.unique + readOnly), so the import infinite-recurses
          # / errors. The profile's only install-relevant provision is the
          # nixos-install binary, provided here via nixos-install-tools instead.
          installer =
            { pkgs, ... }:
            {
              imports = [ commonConfig ];
              # Boot the installer under OVMFFull so PCR 7 is measured by the
              # same firmware the target boots under (required for the PCR-7
              # token to unseal across the two VMs).
              virtualisation.useEFIBoot = true;
              # Serve the host nix store read-only so nixos-install substitutes
              # the pre-built testToplevel with no network (no substitutes).
              virtualisation.mountHostNixStore = true;
              # Boot the installer from a small /dev/vdb so /dev/vda (the shared
              # target.qcow2) stays blank as the install target during AND after
              # install (installer.nix:722-726).
              virtualisation.emptyDiskImages = [ 1024 ];
              virtualisation.rootDevice = "/dev/vdb";
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              # The dots flake source the installer reads disko.nix + nix/ from.
              # `dotsFlake` is flake `self` (path-coercible via outPath); if the
              # path type ever rejects the attrset, use `dotsFlake.outPath`.
              environment.etc."dots".source = dotsFlake;
              environment.systemPackages = [
                pkgs.nixos-install-tools
                pkgs.disko
                pkgs.cryptsetup
                pkgs.tpm2-tools
                pkgs.nixos-facter
              ];
              # Everything nixos-install needs to evaluate + copy the closure
              # offline: the test-settings toplevel + flake input sources.
              system.extraDependencies = [ testToplevel ] ++ flakeInputPaths;
            };

          target =
            { ... }:
            {
              imports = [ commonConfig ];
              virtualisation = {
                # Boot the installed disk via Limine (installer.nix:809-812).
                useBootLoader = true;
                useEFIBoot = true;
                useDefaultFilesystems = false;
                # Limine installs to \EFI\BOOT\BOOTX64.EFI (canTouchEfiVariables
                # = false, removable path) — firmware boots it from the default
                # removable path, so no persistent EFI NVRAM vars are needed
                # (installer.nix:812 sets efi.keepVariables = false).
                efi.keepVariables = false;
                # Dummy root; the real root comes from the installed system's
                # bootloader/kernel (installer.nix:814-817).
                fileSystems."/" = {
                  device = "/dev/disk/by-label/this-is-not-real-and-will-never-be-used";
                  fsType = "ext4";
                };
              };
            };
        };

      testScript =
        ''
          import base64

          installer.start()
          installer.wait_for_unit("multi-user.target")
          installer.succeed("udevadm settle")

          with subtest("Generate the one-shot LUKS keyfile"):
              installer.succeed("umask 077; head -c 64 /dev/urandom > /tmp/dots-luks-pass")

          with subtest("disko partition + format + mount on /dev/vda"):
              installer.succeed(
                  """disko --mode destroy,format,mount --yes-wipe-all-disks"""
                  """ --arg disks '["/dev/vda"]'"""
                  """ --argstr swapSize 1G /etc/dots/nix/disko.nix >&2"""
              )

          with subtest("Stage a writable flake copy + write test settings.nix"):
              installer.succeed(
                  "rm -rf /tmp/dots-flake"
                  " && mkdir -p /tmp/dots-flake"
                  " && cp -rTL /etc/dots /tmp/dots-flake"
                  " && chmod -R u+w /tmp/dots-flake"
              )
              # base64 round-trips the file in with zero quoting ambiguity — no
              # shell heredoc indentation pitfalls, no $ expansion.
              settings_nix = """{
                username = "test";
                hostname = "test";
                disks = ["/dev/vda"];
                swapSize = "1G";
                gitName = "Test User";
                gitEmail = "test@example.com";
              }
              """
              s_b64 = base64.b64encode(settings_nix.encode()).decode()
              installer.succeed(f"printf '%s' {s_b64} | base64 -d > /tmp/dots-flake/nix/settings.nix")
              installer.succeed("cat /tmp/dots-flake/nix/settings.nix >&2")

          with subtest("nixos-install completes — no machine-id abort under impermanence"):
              # The load-bearing step: Limine (not systemd-boot) is the installed
              # bootloader precisely so nixos-install does not abort on the empty
              # /etc/machine-id that impermanence produces.
              installer.succeed(
                  "nixos-install --root /mnt --no-root-passwd"
                  " --flake /tmp/dots-flake#tokyonight < /dev/null >&2"
              )

          with subtest("Enroll TPM2 PCR-7 token + LUKS recovery key"):
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --tpm2-device=auto --tpm2-pcrs=7 /dev/tokyonightvg/root >&2"
              )
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --recovery-key /dev/tokyonightvg/root >&2"
              )

          with subtest("Shred the keyfile and shut down the installer"):
              installer.succeed("shred -u /tmp/dots-luks-pass")
              installer.succeed("umount -R /mnt || true")
              installer.succeed("sync")
              installer.shutdown()

          # Share state_dir (installer.nix:255) — shares BOTH the qcow2 disk
          # file AND the swtpm state (forced to the same dir via the shared
          # system.name in commonConfig), so the target's TPM2 is the chip the
          # installer enrolled against.
          target.state_dir = installer.state_dir
          target.start()

          with subtest("Installed system boots via Limine + TPM2 auto-unlock"):
              target.wait_for_unit("multi-user.target")
              # multi-user.target is only reachable if the LUKS root auto-unlocked
              # via the TPM2 token (no recovery-key prompt in a non-interactive
              # boot). Confirm the mapper is the root backing device.
              assert "/dev/mapper/cryptroot" in target.succeed("mount"), \
                  "cryptroot not mounted — TPM2 PCR-7 unseal did not fire"
        '';
    };

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
  limine-install-boot = limineInstallBootTest;
}