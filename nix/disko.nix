# Single source of truth for the disk layout — same shape as the retired
# Gentoo installer's partition.py (git history): systemd-repart with ESP 2G,
# TPM2-LUKS2 btrfs root, random-key swap.
# Consumed two ways, keep them from drifting:
#   - disko CLI on the LiveISO:
#       disko --mode destroy,format,mount --argstr disk /dev/sdX --argstr swapSize 32G nix/disko.nix
#   - imported by flake.nix into the system config (generates fileSystems).
# When neither disk nor disks is supplied, disko autodetects one whole-disk
# device. Multiple matches require an explicit choice so autodetection can
# never wipe several disks.
# GPT order: ESP, swap (fixed size), LUKS root fills the remainder.
{
  disk ? null,
  disks ? null,
  swapSize ? "32G",
  ...
}:
let
  isWholeDisk =
    name: builtins.match "(mmcblk[0-9]+|nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+)" name != null;
  detectedDisks =
    if disk != null then
      [ disk ]
    else if disks != null then
      if builtins.isList disks then disks else [ disks ]
    else
      builtins.map (name: "/dev/${name}") (
        builtins.filter isWholeDisk (builtins.attrNames (builtins.readDir "/dev"))
      );
  selectedDisk =
    if builtins.length detectedDisks == 1 then
      builtins.head detectedDisks
    else if detectedDisks == [ ] then
      throw "disko could not autodetect a target disk; pass --argstr disk /dev/…"
    else
      throw "disko found multiple target disks; pass --argstr disk /dev/… explicitly";
in
{
  disko.devices.disk.main = {
    device = selectedDisk;
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
  };
}
