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
}
