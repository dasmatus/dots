# Host prerequisites for unprivileged per-app sandboxes. The chosen design
# runs `systemd-nspawn`/`systemd-vmspawn` entirely inside the user session —
# uid 1000, no root, no setuid, no file capabilities — because the system-scope
# alternative (`machinectl bind`/`bind-volume`) maps to the polkit action
# `org.freedesktop.machine1.manage-machines`, which is `auth_admin_keep`: a
# real admin password prompt, even for an active wheel session, on every
# `nix run .#<app>`. The unprivileged `--user` scope never calls that action,
# so it never prompts. Two things the user-scope route needs are missing from
# a stock NixOS system; this module supplies them.
#
# Deliberately its own file rather than folded into virtualisation.nix: that
# module is the libvirt/virt-manager desktop stack and exists for an unrelated
# reason. Adding this module changes nothing by itself — both units below only
# take effect once someone runs `nixos-rebuild switch`.
{ pkgs, ... }:
{
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
  systemd.additionalUpstreamSystemUnits = [
    "systemd-nsresourced.service"
    "systemd-nsresourced.socket"
  ];

  # additionalUpstreamSystemUnits only makes the unit file available; NixOS
  # never runs `systemctl enable`, so nothing in the unit's own [Install]
  # section gets interpreted. The socket needs an explicit wantedBy to start
  # at boot. The service doesn't: it's socket-activated (Requires= the socket
  # unit), so the socket pulls it in on first connection.
  systemd.sockets.systemd-nsresourced.wantedBy = [ "sockets.target" ];

  # nsresourced's Varlink socket (/run/systemd/io.systemd.NamespaceResource)
  # ships with SocketMode=0666 and no polkit check at all — any local process
  # can dial it directly. That's deliberate upstream design, and it's exactly
  # what makes the unprivileged-user-scope route work with zero prompts,
  # unlike the system-scope machinectl route rejected above.

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
