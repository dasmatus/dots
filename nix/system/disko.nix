# Single source of truth for the disk layout — same goals as the retired
# Gentoo installer's partition.py (git history): ESP 2G, TPM2-LUKS2 btrfs
# root, random-key swap. Realised on LVM so the volume group can span every
# selected disk: one PV per disk, one VG (`tokyonightvg`), logical volumes for
# swap and the LUKS root. ESP stays a raw partition on the first disk (boot
# loaders can't read LVM).
# Consumed two ways, keep them from drifting:
#   - disko CLI on the LiveISO:
#       disko --mode destroy,format,mount --arg disks '["/dev/sda" "/dev/sdb"]' \
#             --argstr swapSize 32G nix/system/disko.nix
#   - imported by flake.nix into the system config (generates fileSystems).
# When neither disk nor disks is supplied, disko autodetects one whole-disk
# device. Multiple matches throw — autodetection must never silently wipe
# several disks, so a multi-disk span always comes from an explicit `disks`.
{
  disk ? null,
  disks ? null,
  swapSize ? "32G",
  ...
}:
let
  isWholeDisk =
    name: builtins.match "(mmcblk[0-9]+|nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|xvd[a-z]+)" name != null;
  # Normalise every entry path to a single `selectedDisks` list, honouring an
  # explicit `disks` list, then a legacy single `disk`, then /dev autodetect.
  detectedDisks =
    if disks != null then
      if builtins.isList disks then disks else [ disks ]
    else if disk != null then
      [ disk ]
    else
      builtins.map (name: "/dev/${name}") (
        builtins.filter isWholeDisk (builtins.attrNames (builtins.readDir "/dev"))
      );
  selectedDisks =
    if detectedDisks == [ ] then
      throw "disko could not autodetect a target disk; pass --arg disks '[\"/dev/…\"]'"
    else if builtins.length detectedDisks > 1 && disks == null && disk == null then
      throw "disko found multiple target disks; pass --arg disks '[\"/dev/…\"]' explicitly"
    else
      detectedDisks;

  # One disk attr per selected device. The first disk also carries the ESP;
  # every disk carries a single LVM-PV partition that joins `tokyonightvg`.
  # builtins-only (no lib) so the disko CLI can evaluate this file with just
  # its --arg/--argstr args — it doesn't inject lib the way nixosSystem does.
  vgName = "tokyonightvg";
  diskEntry = i: d: {
    name = "main${toString i}";
    value = {
      device = d;
      type = "disk";
      content = {
        type = "gpt";
        partitions =
          (
            if i == 0 then
              {
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
              }
            else
              { }
          )
          // {
            pv = {
              priority = 2;
              size = "100%";
              content = {
                type = "lvm_pv";
                vg = vgName;
              };
            };
          };
      };
    };
  };
  diskEntries = builtins.genList (i: diskEntry i (builtins.elemAt selectedDisks i)) (
    builtins.length selectedDisks
  );
in
{
  disko.devices = {
    disk = builtins.listToAttrs diskEntries;

    # disko allocates fixed-size LVs (priority 1000) before any 100%FREE LV
    # (priority 1251), so `swap` claims its size first and `root` fills the
    # rest — no need to game LV attribute order.
    lvm_vg.${vgName} = {
      type = "lvm_vg";
      lvs = {
        swap = {
          size = swapSize;
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
        root = {
          size = "100%FREE";
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
                # No "@root"→`/`: the root is a tmpfs (declared in
                # nix/modules/system/impermanence.nix) so system state is wiped each boot
                # and only the dirs bind-mounted from /persist survive. The store
                # lives on its own persistent subvol so /nix/store survives the
                # wipe; /persist is the impermanence source.
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [
                    "compress=zstd:1"
                    "noatime"
                  ];
                };
                "@persist" = {
                  mountpoint = "/persist";
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
