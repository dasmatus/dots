# Secure Boot via lanzaboote — ON by default. As a side effect this also
# builds Unified Kernel Images (UKIs) by default: lanzaboote builds a signed
# UKI per generation and installs it to the ESP, replacing plain systemd-boot
# (which it disables with mkForce below). nix/modules/boot.nix keeps the
# plain systemd-boot config for the fallback case where this flag is turned
# off.
#
# Although the flag is on by default, the firmware still has to *trust* the
# signing keys before a signed UKI will boot — this is a one-time, post-install
# enrollment because key enrollment needs the firmware in Setup Mode:
#   sudo sbctl create-keys
#   (reboot into firmware, enable Setup Mode)
#   sudo sbctl enroll-keys --microsoft
#   nixos-rebuild switch
# Until that dance is done, either keep the firmware's Secure Boot off (the
# signed UKI boots unsigned-verified... i.e. unverified, so fine) or set
# dots.secureboot.enable = false to fall back to plain systemd-boot. The
# retired Gentoo installer generated db keys at install time (git history).
#
# Keys are generated UNCONDITIONALLY by the dots-sbctl-keygen oneshot below
# (regardless of the firmware Secure Boot state), so they're ready to enroll
# the moment the user flips Secure Boot on. The service additionally probes
# the EFI "SecureBoot" variable at runtime and warns (but does not fail) when
# Secure Boot is off in firmware — that's a heads-up that the signed UKIs
# lanzaboote ships will boot unverified until the user enables + enrolls.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  options.dots.secureboot.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Secure Boot signing via lanzaboote (and thus UKI building).";
  };

  config = lib.mkMerge [
    {
      # sbctl is always available — for the keygen service below and for the
      # manual `sbctl enroll-keys` post-install dance.
      environment.systemPackages = [ pkgs.sbctl ];

      # Always generate the sbctl db/PK/KEK keypair on the installed system,
      # even when Secure Boot is currently off in firmware, so the keys are
      # ready to enroll the moment the user flips Secure Boot on. Idempotent:
      # sbctl create-keys refuses to clobber existing keys, so we skip the
      # call when /var/lib/sbctl/keys already exists. Conditioned on EFI so
      # BIOS/LiveISO builds no-op. Runs once per boot (Type=oneshot +
      # RemainAfterExit). The efivar probe below reads the SecureBoot
      # variable's value byte (offset 4, after the 4-byte attribute header)
      # and warns when firmware Secure Boot is off — a heads-up that the
      # signed UKIs will boot unverified until the user enables + enrolls.
      systemd.services.dots-sbctl-keygen = {
        description = "Generate sbctl Secure Boot keys if absent";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig.ConditionPathIsDirectory = "/sys/firmware/efi";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          sbctl=${lib.getExe pkgs.sbctl}
          if [ -d /var/lib/sbctl/keys ]; then
            echo "dots-sbctl-keygen: sbctl keys already present, skipping keygen"
          else
            "$sbctl" create-keys
          fi

          # Probe the firmware Secure Boot state and warn if it's off. The
          # SecureBoot EFI variable (EFI_GLOBAL_VARIABLE,
          # 8be4df61-93ca-11d2-aa0d-00e09803243c) is a 4-byte attribute header
          # followed by a 1-byte value (0x01 = on, 0x00 = off). od skips NUL
          # bytes cleanly; the value byte is the last one on the line.
          sbvar=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e09803243c
          if [ -r "$sbvar" ]; then
            val=$(od -An -tu1 -j4 -N1 "$sbvar" 2>/dev/null | tr -dc '0-9')
            if [ "$val" = "1" ]; then
              echo "dots-sbctl-keygen: firmware Secure Boot is ON — enroll the keys (sbctl enroll-keys --microsoft) to verify signed UKIs."
            elif [ "$val" = "0" ]; then
              echo "dots-sbctl-keygen: WARNING — firmware Secure Boot is OFF; the signed UKIs lanzaboote ships will boot unverified until you enable Secure Boot and enroll the keys."
            else
              echo "dots-sbctl-keygen: could not parse firmware Secure Boot state (value byte='$val'), proceeding with keys as-is."
            fi
          fi
        '';
      };
    }
    (lib.mkIf config.dots.secureboot.enable {
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";
      };
    })
  ];
}
