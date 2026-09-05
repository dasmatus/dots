# Host prerequisites for unprivileged per-app sandboxes. The chosen design
# runs `systemd-nspawn`/`systemd-vmspawn` entirely inside the user session —
# uid 1000, no root, no setuid, no file capabilities — because the system-scope
# alternative (`machinectl bind`/`bind-volume`) maps to the polkit action
# `org.freedesktop.machine1.manage-machines`, which is `auth_admin_keep`: a
# real admin password prompt, even for an active wheel session, on every
# `nix run .#<app>`. The unprivileged `--user` scope never calls that action,
# so it never prompts. Three things the user-scope route needs are missing
# from a stock NixOS system; this module supplies them.
#
# Deliberately its own file rather than folded into virtualisation.nix: that
# module is the libvirt/virt-manager desktop stack and exists for an unrelated
# reason. Adding this module changes nothing by itself — both units below only
# take effect once someone runs `nixos-rebuild switch`.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # virtiofsd has to be placed in a user namespace with uid 0 mapped, and
  # doing that needs a delegated subordinate UID/GID range. This host has
  # neither /etc/subuid nor /etc/subgid, so the mapping is refused and
  # `systemd-vmspawn` dies with:
  #
  #   Failed to enter user namespace for virtiofsd: Operation not permitted
  #
  # Confirmed by running virtiofsd directly, outside vmspawn, in each of its
  # three sandbox modes: `--sandbox=namespace` warns "Couldn't set the
  # process uid as root: -1" (the same missing-range symptom), `--sandbox=chroot`
  # refuses outright as root-only, and `--sandbox=none` starts cleanly and
  # reaches "Waiting for vhost-user socket connection". So virtiofsd itself
  # runs fine unprivileged — only the namespace placement fails, and only for
  # want of a range to map.
  #
  # This matters beyond the VM tier's root filesystem: every `--bind=` share
  # is served by virtiofsd, so the repo bind and the live-grant share both
  # depend on it. Without this, nothing the sandbox does is actually confined.
  # Written directly rather than through `users.users.<name>.autoSubUidGidRange`,
  # which is silently a no-op on this system. That option is consumed by
  # nixpkgs' update-users-groups.pl — the legacy Perl activation script that
  # rewrites /etc/subuid and /etc/subgid. This host runs userborn instead
  # (nix/modules/system/users.nix sets services.userborn.enable, and the NixOS
  # users-groups module blanks the activation script when it is on), and
  # userborn has no subuid handling whatsoever. Setting the option changed
  # nothing: /etc/subuid still did not exist after a rebuild, and virtiofsd
  # still could not be placed in a user namespace.
  #
  # 100000 with a 65536-wide range is the same shape the Perl script's own
  # auto-allocation uses, so nothing here is novel except that it actually
  # lands on a userborn system.
  # Derived from the declared user set rather than naming anyone: every normal
  # user gets a range, and each range is keyed off that user's own uid so two
  # users can never be handed overlapping subordinate ids. Adding a second user
  # to this system needs no edit here.
  environment.etc =
    let
      normalUsers = lib.filterAttrs (_: user: user.isNormalUser) config.users.users;

      # 65536 ids per user, the conventional width, starting at 100000 — the
      # same base and stride the Perl script's own auto-allocation uses.
      #
      # Indexed by position in the sorted name list, deliberately not by uid:
      # `users.users.<name>.uid` is null unless someone sets it explicitly, and
      # this host does not — userborn assigns uids at runtime, so an arithmetic
      # expression over uid fails at evaluation time rather than producing a
      # wrong answer. Sorted names are stable across rebuilds and give every
      # user a block disjoint from every other's, which is the only property
      # the range actually has to have.
      rangeFor =
        index: name: "${name}:${toString (100000 + index * 65536)}:65536";

      ranges = lib.concatStringsSep "\n" (
        lib.imap0 rangeFor (lib.sort (a: b: a < b) (lib.attrNames normalUsers))
      );
    in
    {
      "subuid".text = "${ranges}\n";
      "subgid".text = "${ranges}\n";
    };

  # systemd-nspawn's unprivileged `--user` scope hard-requires
  # systemd-nsresourced: without it, nspawn fails with "Failed to connect to
  # nsresourced: No such file or directory". Both the binary and the unit
  # files already ship in this systemd (261.1) — NixOS's systemd derivation
  # parks them under <systemd>/example/systemd/system/ instead of installing
  # them, so `systemctl list-unit-files | grep nsresourced` comes back empty
  # on an unmodified system.
  #
  # `additionalUpstreamSystemUnits` is the mechanism NixOS's own systemd
  # module uses for exactly this shape of problem — see upstream's
  # userdbd.nix, homed.nix and coredump.nix, all units nixpkgs ships under
  # example/ and enables this same way. It resolves the named unit from
  # <package>/example/systemd/system when the unit isn't already on the
  # normal search path, so this references what ships instead of
  # transcribing unit text that would silently drift on the next systemd
  # version bump.
  #
  # systemd-mountfsd is the second, sibling requirement, found the same way:
  # once nsresourced let `systemd-nspawn --user` past the UID-range hurdle
  # above, the very next thing it does — mounting the `--ephemeral` overlay
  # over a plain (non-btrfs) `--directory=` tree — fails with "Failed to
  # connect to mountfsd: No such file or directory" without it. Confirmed
  # directly by the VM test (tests/sandbox.nix, "start a long-lived container"
  # subtest): nsresourced alone was NOT enough to get a machine running at
  # all, only far enough to hit this next missing daemon. Same shape as
  # nsresourced in every respect that matters here — ships in this systemd,
  # parked under `example/systemd/system/`, socket-activated, no polkit.
  systemd.additionalUpstreamSystemUnits = [
    "systemd-nsresourced.service"
    "systemd-nsresourced.socket"
    "systemd-mountfsd.service"
    "systemd-mountfsd.socket"
  ];

  # additionalUpstreamSystemUnits only makes the unit file available; NixOS
  # never runs `systemctl enable`, so nothing in the unit's own [Install]
  # section gets interpreted. The socket needs an explicit wantedBy to start
  # at boot. The service doesn't: it's socket-activated (Requires= the socket
  # unit), so the socket pulls it in on first connection.
  systemd.sockets.systemd-nsresourced.wantedBy = [ "sockets.target" ];
  systemd.sockets.systemd-mountfsd.wantedBy = [ "sockets.target" ];

  # Both Varlink sockets (nsresourced's /run/systemd/io.systemd.NamespaceResource,
  # mountfsd's /run/systemd/io.systemd.MountFileSystem) ship with
  # SocketMode=0666 and no polkit check at all — any local process can dial
  # either directly. That's deliberate upstream design, and it's exactly what
  # makes the unprivileged-user-scope route work with zero prompts, unlike
  # the system-scope machinectl route rejected above.

  # systemd-vmspawn needs virtiofsd to serve `--bind=` shares into a VM — it's
  # how live permission grants reach the VM tier at all, so without it that
  # half of the sandbox feature cannot work. It is genuinely absent from this
  # system (unlike OVMF, which is already present and wired via
  # nix/modules/system/virtualisation.nix's libvirtd/QEMU stack — firmware
  # discovery is a separate, deliberately unsolved problem: `systemd-vmspawn
  # --firmware=list` finds nothing because NixOS doesn't populate
  # /usr/share/qemu/firmware-style descriptor JSONs, and the launcher passes
  # an explicit `--firmware=<store path>` instead of relying on discovery, so
  # no descriptor directory is added here).
  #
  # vmspawn locates the binary with find_executable("virtiofsd"), i.e. a PATH
  # search (falling back to FHS paths like /usr/libexec/virtiofsd that don't
  # exist on NixOS), so it has to land in systemPackages rather than just be
  # buildable from this flake.
  environment.systemPackages = [ pkgs.virtiofsd ];
}
