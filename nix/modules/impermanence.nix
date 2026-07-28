# Ephemeral root via nixos-impermanence. `/` is a tmpfs (wiped each boot); the
# btrfs subvols `@nix` (`/nix`) and `@persist` (`/persist`) are disko-managed
# and marked neededForBoot so the store + persistence source come up in the
# initrd. nixos-impermanence then bind-mounts the curated set below from
# /persist over the live tree, so those paths survive the root wipe. /home,
# /.snapshots and /var/tmp/notmpfs stay persistent btrfs subvols on their own
# (user data / snapshots / large build dirs) and are NOT routed through
# impermanence — no home-data migration.
#
# Coexists with system.etc.overlay.mutable = false (core.nix): impermanence
# persists at the filesystem (bind-mount) layer, independent of /etc
# generation, so it bind-mounts over the immutable /etc paths fine. The
# load-bearing entry is /var/lib/nixos — userborn writes passwd/shadow/group
# there (users.nix); persisting it is what keeps login working across the
# ephemeral root. /var/lib/sbctl must persist too or the Secure Boot keys
# regenerate each boot and the previously-signed UKIs in /boot fail db
# verification (lanzaboote signs from /var/lib/sbctl/keys/db/db.pem).
{ lib, ... }:
{
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "defaults"
      # Half of RAM — root tmpfs holds /run, /tmp and transient state; the
      # big stuff (/nix, /home, /persist) is on btrfs, so this stays small.
      "size=50%"
      "mode=0755"
    ];
  };

  # disko generates fileSystems."/persist" (subvol=@persist) and
  # fileSystems."/nix" (subvol=@nix); force neededForBoot so /persist is mounted
  # in the initrd before the impermanence bind-mounts run in stage 2, and /nix
  # is up before nixos-init activates /etc from the erofs image in the store.
  fileSystems."/persist".neededForBoot = lib.mkForce true;
  fileSystems."/nix".neededForBoot = lib.mkForce true;

  environment.persistence."/persist" = {
    enable = true;
    # Hide the bind-mounts from `mount`/findmnt for a cleaner tree.
    hideMounts = true;
    directories = [
      "/var/lib/nixos" # userborn passwd/shadow/group — login survives reboot
      "/var/lib/sbctl" # Secure Boot keys — else signed UKIs fail db verification
      "/etc/NetworkManager/system-connections" # Wi-Fi profiles (installer-seeded)
      "/var/lib/NetworkManager" # NM state
      "/var/lib/dots" # install answers (settings.nix/facter.json) for dots-clone
      "/var/log" # journal across reboots
    ];
    # /etc/machine-id intentionally NOT persisted: it regenerates each boot,
    # which is acceptable for a desktop. Add it here if a stable machine
    # identity is ever required (e.g. for machine-id-licensed software).
  };
}
