# Single source of truth for the disk layout — parity with installer/partition.py
# (systemd-repart: ESP 2G, TPM2-LUKS2 btrfs root, random-key swap).
# Consumed two ways, keep them from drifting:
#   - disko CLI on the LiveISO:
#       disko --mode destroy,format,mount --argstr disk /dev/sdX --argstr swapSize 32G nix/disko.nix
#   - imported by flake.nix into the system config (generates fileSystems).
# GPT order: ESP, swap (fixed size), LUKS root fills the remainder.
{ disk ? "/dev/nvme0n1", swapSize ? "32G", ... }:
{
  disko.devices.disk.main = {
    device = disk;
    type = "disk";
    content = {
      type = "gpt";
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
                  mountOptions = [ "compress=zstd:1" "noatime" ];
                };
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [ "compress=zstd:1" "noatime" ];
                };
                "@snapshots" = {
                  mountpoint = "/.snapshots";
                  mountOptions = [ "compress=zstd:1" "noatime" ];
                };
                "@builds" = {
                  mountpoint = "/var/tmp/notmpfs";
                  mountOptions = [ "compress=zstd:1" "noatime" "nodatacow" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
