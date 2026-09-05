# User-scope `systemd-machined` — the unauthenticated `machinectl --user`
# backend the per-app sandbox (rust/dots-sandbox, a parallel agent's work)
# depends on. NixOS wires none of this; this module is the whole reason it
# exists.
#
# ---------------------------------------------------------------------------
# Why user scope, not system scope (the polkit rejection)
# ---------------------------------------------------------------------------
# The sandbox runs unprivileged, as the desktop user. On systemd 261, both
# `systemd-nspawn` and `systemd-vmspawn` automatically switch to a `--user`
# scope when invoked as a non-root uid, and a per-user `systemd-machined`
# answers `machinectl --user` / `busctl --user` with NO authentication
# whatsoever — the D-Bus policy for the user session bus has no admin
# concept to gate on.
#
# The system-scope equivalent does: `machinectl bind` (and friends) map to
# the polkit action `org.freedesktop.machine1.manage-machines`, which
# nixpkgs' own `share/polkit-1/actions/org.freedesktop.machine1.policy`
# ships as `auth_admin_keep` — an admin password prompt on every single app
# launch. A sandbox whose entire point is "click an icon, get an isolated
# container" cannot eat a password prompt per click, so system-scope
# `machined` + polkit was rejected outright in favour of the user-scope
# instance this module wires. That rejection is the one fact worth
# rediscovering-proofing here: it is why this file exists instead of a
# five-line addition to `nix/modules/system/`.
#
# ---------------------------------------------------------------------------
# What NixOS actually curates, and what it leaves stranded
# ---------------------------------------------------------------------------
# `pkgs.systemd` ships unit files for BOTH scopes under
# `$out/example/systemd/{system,user}/`. `example/` is upstream's own
# packaging convention: units land there at build time, and a distro's
# NixOS/Home-Manager module is expected to promote whichever subset it
# wants into the real unit search path. NixOS's system module
# (`nixos/modules/system/boot/systemd.nix`, `additionalUpstreamSystemUnits`
# around line 189) promotes the SYSTEM-scope `systemd-machined.service` +
# `.socket` this way, gated on `cfg.package.withMachined`. There is no
# equivalent list for the `--user` manager anywhere in nixpkgs, and Home
# Manager has no curation mechanism of its own — confirmed by
# `systemctl --user list-unit-files | grep machined` returning nothing on
# a real, fully-built machine. `nsresourced` (the companion the SYSTEM-scope
# sibling module in `nix/modules/system/` wires) is in the identical
# situation for the reverse reason: it appears nowhere in nixpkgs' `nixos/`
# tree at all, system or user.
#
# ---------------------------------------------------------------------------
# The design choice: socket + bus activation, not a permanently-running unit
# ---------------------------------------------------------------------------
# `systemd-machined` is dormant in every session that never opens a
# sandboxed app — which, on a laptop, is most of them. Running it
# unconditionally for the whole session would be a daemon nobody asked for,
# forever, for a feature most logins never touch. So this module leans on
# on-demand activation, on two independent paths that both terminate at the
# exact same `systemd-machined.service`:
#
#   1. Varlink, socket-activated — the path the sandbox itself rides. Reading
#      the strings out of the shipped `libsystemd-shared-*.so`, both
#      `systemd-nspawn` and `systemd-vmspawn` link the `io.systemd.Machine`
#      varlink interface (`io.systemd.Machine.Register`/`.Unregister`)
#      against the exact socket path `systemd-machined.socket` listens on
#      (`%t/systemd/machine/io.systemd.Machine` — see its `ListenStream=`
#      below). A container/VM launched directly, with no unit at all,
#      registers itself with `machined` over this socket; the kernel wakes
#      `machined` on the first connection and nothing runs before that.
#      Upstream's OWN packaging already intends this socket enabled: the
#      shipped `example/systemd/user/sockets.target.wants/` directory
#      carries a prebaked `systemd-machined.socket` symlink, right alongside
#      `systemd-ask-password.socket`, `systemd-importd.socket`,
#      `systemd-journalctl.socket` and `systemd-storage-fs.socket` — every
#      one of them lazy-by-default upstream. `systemd-machined.service`
#      itself ships with NO `[Install]` section at all, i.e. upstream never
#      intends it started any other way. This module is completing wiring
#      upstream already decided on, not inventing a new policy — it is only
#      stranded because nothing curates the user tree at all (see above).
#
#   2. Classic D-Bus, bus-activated — the path `machinectl --user` /
#      `busctl --user` ride for querying and managing whatever is already
#      registered. This is a SEPARATE mechanism from the socket above: the
#      session bus (`dbus-broker` here — confirmed via
#      `systemctl --user status dbus.service`) discovers the bus name
#      `org.freedesktop.machine1` from the packaged
#      `share/dbus-1/services/org.freedesktop.machine1.service`, whose
#      `SystemdService=dbus-org.freedesktop.machine1.service` key tells it
#      to ask `systemd --user` to start a unit by that exact name — not to
#      connect to any socket. Upstream ships that unit as a plain alias: a
#      symlink `dbus-org.freedesktop.machine1.service -> systemd-machined.service`
#      (verified: identical inode/content in
#      `$out/example/systemd/user/`, and the SYSTEM-scope build on this
#      machine wires the literal same symlink at
#      `/etc/systemd/system/dbus-org.freedesktop.machine1.service`). Without
#      it, that lookup fails outright — not hypothetically: this machine's
#      own `dbus-broker-launch` log carries
#      `Activation request for 'org.freedesktop.machine1' failed: The
#      systemd unit 'dbus-org.freedesktop.machine1.service' could not be
#      found.` from an earlier probe of exactly this gap, on the user
#      session bus, before this module existed. Wiring the alias needs no
#      enablement of its own: bus-name activation triggers off the unit
#      merely being loadable, the same way `hostnamed`/`timedated`/
#      `localed`'s own `dbus-org.freedesktop.*` aliases work with no
#      `WantedBy=` anywhere in sight (see the very same
#      `additionalUpstreamSystemUnits` list this comment already points at,
#      which curates those dbus alias units for those three daemons but
#      never for machined — an nixpkgs omission worth flagging, not
#      something to route around by transcribing).
#
# `machine.slice` is wired too, for a narrower reason: `systemd-machined
# .service` itself carries `Wants=machine.slice` / `After=machine.slice`,
# and a `Wants=` naming a unit that is not even loadable silently no-ops —
# better to give it something real to pull in than let that directive rot.
# It is a plain slice (no process of its own), so enabling it costs nothing.
#
# `machines.target` is deliberately NOT wired: upstream's own copy exists
# only to give boot-time, unit-managed containers/VMs a synchronisation
# point to report readiness against (`Before=default.target`,
# `WantedBy=default.target` — plus `PartOf=machines.target` on the two
# template units below). Nothing in this design launches a container as a
# managed unit at session start, so nothing would ever reach it.
#
# ---------------------------------------------------------------------------
# Why xdg.configFile references instead of home-manager's `systemd.user.*`
# ---------------------------------------------------------------------------
# The rest of this repo's home-manager units (e.g.
# `nix/home/apps/settings-menu.nix`'s hyprpolkitagent, or
# `nix/home/desktop/quickshell/default.nix`'s own unit) restate the package's
# shipped unit through home-manager's structured `systemd.user.services`
# attrs, store-pinning only the `ExecStart`. That is fine for units whose
# only correctness-bearing line IS the executable path. It is the wrong
# call here: `systemd-machined.service` carries a real hardening surface —
# `NoNewPrivileges`, `RestrictAddressFamilies`, `SystemCallFilter`,
# `LockPersonality`, `MemoryDenyWriteExecute`, a watchdog — every one of
# which a hand-transcribed Nix attrset would silently stop tracking the
# instant a systemd release adds, removes, or tightens one. Referencing the
# shipped file by store path instead means the next `pkgs.systemd` bump
# carries whatever upstream changed, automatically, with nothing here to
# go stale. `xdg.configFile.<name>.source` is how that reference is
# expressed — a real symlink into the exact same systemd derivation NixOS
# itself runs (`nix/modules/system/users.nix`'s `useGlobalPkgs = true`
# guarantees `pkgs.systemd` here IS that same store path, not a
# separately-evaluated one), not a copy of its text.
#
# The one place this trades away is home-manager's `wantedBy` sugar for
# `systemd.user.sockets`, which only exists for units built through that
# same structured path. `systemd-machined.socket` ships with no
# `[Install]` section anyway (see above — its enablement is a prebaked
# `.wants/` symlink, not an `Install.WantedBy` line), so that sugar would
# have bought nothing here even if used; the manual `sockets.target.wants`
# symlink below just replicates upstream's own mechanism verbatim.
#
# ---------------------------------------------------------------------------
# Why the `systemd-nspawn@.service` / `systemd-vmspawn@.service` user
# templates are NOT wired
# ---------------------------------------------------------------------------
# Both ship in the same `example/systemd/user/` tree, and both are a
# different feature entirely: `PartOf=machines.target` +
# `WantedBy=machines.target`, driven by `machinectl start <name>` (or a
# declarative `/etc/systemd/nspawn/<name>.nspawn` settings file via
# `--settings=override`), running a FIXED, opinionated command line
# (`--boot --network-veth -U …` for nspawn; `--network-tap …` for vmspawn)
# that boots a persistent, full-init container/VM by name. The sandbox
# launcher this module exists for invokes the `systemd-nspawn` /
# `systemd-vmspawn` BINARIES directly, per app launch, with its own flags —
# never through `systemctl start systemd-nspawn@…`. Wiring an unused
# template is not free insurance; it is a unit nobody starts that someone
# later has to explain away. Left out on purpose.
{
  pkgs,
  lib,
  dotsSandbox,
  ...
}:
let
  systemdUser = "${pkgs.systemd}/example/systemd/user";
in
{
  # The sandbox CLI itself. Without it on PATH the Settings panel's Security
  # page waits forever on `dots-sandbox report --json` and
  # `dots-sandbox policy dump` — it renders "Reading…" and never resolves,
  # because the command it shells out to does not exist. Packaging the crate
  # in the flake made it buildable, not installed; this is what installs it.
  home.packages = [ dotsSandbox ];

  xdg.configFile = {
    # The daemon. No enablement of its own — reached only via the socket
    # (varlink registration) or the D-Bus alias below (bus-name lookup).
    "systemd/user/systemd-machined.service".source = "${systemdUser}/systemd-machined.service";

    # The varlink listen socket nspawn/vmspawn registration connects to.
    "systemd/user/systemd-machined.socket".source = "${systemdUser}/systemd-machined.socket";
    # Enablement for the socket above — replicated by hand because the unit
    # itself carries no [Install] section for home-manager's wantedBy sugar
    # to hook into; upstream's own packaging enables it the identical way
    # (a prebaked sockets.target.wants/ symlink).
    "systemd/user/sockets.target.wants/systemd-machined.socket".source =
      "${systemdUser}/systemd-machined.socket";

    # The D-Bus bus-activation alias `machinectl --user`/`busctl --user`
    # need — see the long comment above for the dbus-broker log line that
    # proves this is not a hypothetical gap. This placeholder entry is
    # DELIBERATELY WRONG on its own (see the `dotsSandboxMachinedAlias`
    # activation step below, which overwrites it with the real alias) —
    # kept only so this key stays present and store-referenced for
    # tests/sandbox-machined.nix's own checks; the plain
    # `xdg.configFile.<name>.source` mechanism cannot produce what this
    # name actually needs to be, for a reason worth recording in full.
    #
    # Traced with `nix/store/…-systemd-261.1/src/shared/unit-file.c`'s
    # `unit_file_resolve_symlink()` (VM test: tests/sandbox.nix, "THE
    # EXPERIMENT" subtest, where this first showed up as `systemd[…]:
    # dbus-org.freedesktop.machine1.service: Two services allocated for
    # the same bus name org.freedesktop.machine1, refusing operation` —
    # which fails `machinectl --user`'s bus activation outright, every
    # subcommand included, not just `bind`). That function reads ONE hop
    # of the unit file's symlink (`readlinkat`), joins it against the
    # unit's own directory, and — critically — resolves ONLY that (no
    # further hops: `CHASE_NOFOLLOW`) before checking whether the result
    # still lives INSIDE one of systemd's registered unit search
    # directories (`~/.config/systemd/user/`, `/etc/systemd/user/`, a
    # package's `lib/systemd/user/`, …). Land inside one of those and it
    # is an ALIAS for whatever unit name is there; land anywhere else
    # (any `/nix/store/…` path included) and it is loaded as an
    # independent "linked unit file" under its OWN name instead — with
    # its OWN copy of every `[Service]` directive the target file
    # carries, `BusName=org.freedesktop.machine1` (systemd-machined.service's
    # own line) among them. `xdg.configFile.<name>.source` can only ever
    # produce the second shape: home-manager's own activation places the
    # FINAL `~/.config/systemd/user/<name>` symlink pointing directly at
    # a Nix store path, never at a bare, same-directory sibling filename
    # — so no `.source` value here, upstream's own two-hop layout
    # (`dbus-org.freedesktop.machine1.service -> systemd-machined.service`,
    # both under the SAME `example/systemd/user/` directory) included,
    # can ever resolve inside a search directory the way the real,
    # same-directory alias upstream ships does.
    "systemd/user/dbus-org.freedesktop.machine1.service".source =
      "${systemdUser}/systemd-machined.service";

    # The slice systemd-machined.service Wants=/After=. No enablement
    # needed — pulled in transiently by that Wants= once it is loadable.
    "systemd/user/machine.slice".source = "${systemdUser}/machine.slice";
  };

  # The real alias, built the only way that actually lands inside a unit
  # search directory: a literal, same-directory relative symlink, written
  # after linkGeneration has put `systemd-machined.service` in place next
  # to it. `ln -sfn` (not `.source`) is what makes `readlink()`'s one-hop
  # target resolve to `~/.config/systemd/user/systemd-machined.service`
  # itself — a path `unit_file_resolve_symlink()` recognizes as staying
  # inside the search path — rather than to a Nix store path, which is
  # what defeats the alias check every time regardless of which store
  # path the placeholder xdg.configFile entry above points at (see its
  # comment). This is a mechanical necessity of how systemd's alias
  # detection works, not a departure from this module's "reference
  # pkgs.systemd, never hand-copy unit text" rule: the unit CONTENT still
  # comes from pkgs.systemd verbatim via the entries above, unmodified;
  # only the NAME under which it is additionally reachable is wired here.
  home.activation.dotsSandboxMachinedAlias = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ln -sfn systemd-machined.service "$HOME/.config/systemd/user/dbus-org.freedesktop.machine1.service"
  '';
}
