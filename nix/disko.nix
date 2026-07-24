# Single source of truth for the disk layout — This configuration now
# supports LVM. It defines a physical volume group that spans all
# detected disks, and then creates logical volumes for the EFI System
# Partition (ESP), swap, and the root filesystem on top of the volume group.
#
# The configuration is designed to be used with the `disko` CLI tool
# during the installation process. It can also be potentially adapted
# for use within the main NixOS system configuration if needed.
#
# GPT order: ESP, swap (fixed size), LUKS root fills the remainder.
{
  disks ? null, # null → autodetect via /dev/disk/by-id
  swapSize ? "32G",
  lib,
  ...
}:
let
  # ── Nix-native disk autodetection ──────────────────────────────────
  # If `disks` is explicitly passed, honour it (list or single string).
  # Otherwise, scan /dev/disk/by-id for whole-disk symlinks and filter
  # out partitions and USB sticks.
  detectedDisks =
    if disks != null then
      if builtins.isList disks then disks else [ disks ]
    else
      let
        byId = builtins.readDir "/dev/disk/by-id";
        isWholeDisk =
          name:
          !lib.hasInfix "-part" name
          && (lib.hasPrefix "nvme-" name || lib.hasPrefix "wwn-" name || lib.hasPrefix "ata-" name);
      in
      builtins.map (name: "/dev/disk/by-id/${name}") (
        builtins.filter isWholeDisk (builtins.attrNames byId)
      );
in
{
  disko.devices.disk = builtins.listToAttrs (
    builtins.map (
      d:
      lib.nameValuePair d {
        device = d;
        type = "disk";
        content = {
          type = "lvm";
          vgName = "tokyonightvg";
          physicalVolumes = [ d ];
          partitions = {
            esp = {
              priority = 1;
              size = "2G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              priority = 2;
              size = swapSize;
              content = {
                type = "swap";
                randomEncryption = true;
              };
            };
            root = {
              priority = 3;
              size = "100%";
              content = {
                type = "luks";
                name = "cryptroot";
                # Format-time keyslot (root password); the installer enrolls
                # TPM2 (PCR 7) + a recovery key immediately after formatting.
                passwordFile = "/tmp/dots-luks-pass";
                settings = {
                  allowDiscards = true;
                  crypttabExtraOpts = [ "tpm2-device=auto" ];
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ];
                  subvolumes = {
                    "@root" = {
                      mountpoint = "/";
                      mountOptions = [
                        "compress=zstd:1"
                        "noatime"
                      ];
                    };
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = [
                        "compress=zstd:1"
                        "noatime"
                      ];
                    };
                    "@snapshots" = {
                      mountpoint = "/.snapshots";
                      mountOptions = [
                        "compress=zstd:1"
                        "noatime"
                      ];
                    };
                    "@builds" = {
                      mountpoint = "/var/tmp/notmpfs";
                      mountOptions = [
                        "compress=zstd:1"
                        "noatime"
                        "nodatacow"
                      ];
                    };
                  };
                };
              };
            };
          };
        };
      }
    ) detectedDisks
  );
}
