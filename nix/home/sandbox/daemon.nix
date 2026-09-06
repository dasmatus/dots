# The sandbox's session-bus daemon: `dots-sandbox daemon`, owning
# org.dots.Sandbox1 on the user's session bus.
#
# Why this exists: the Settings permissions page was spawning
# `dots-sandbox catalog` on every read. That works, and it is wrong twice
# over — a process spawn per repaint, and no way to learn that a policy
# changed without polling. A long-lived owner answers both: the page reads
# once and subscribes to PolicyChanged.
#
# What it deliberately does NOT do, stated here because a unit called
# "sandbox" invites the opposite assumption:
#
#   - It does not confine anything. Confinement is the wrapper
#     (nix/home/sandbox/wrap.nix), the policy, and the namespace the spawn
#     binaries set up. Starting this service makes the machine no safer by
#     itself, which is why the Description says "policy service" rather
#     than anything with "sandbox" as a verb in it.
#
#   - It is not on the launch path. `dots-sandbox run` never connects to a
#     bus, never waits for one, and works with this stopped. That is not an
#     optimisation: a launcher that depends on a daemon fails closed when
#     the daemon is down, and "no app starts because a background service
#     crashed" is strictly worse than having no daemon at all. DOTS_SANDBOX=0
#     keeps bypassing everything regardless.
#
# Session bus, not system bus. Every path it touches is the user's own
# (~/.config/dots-sandbox/), nothing needs root, and the system bus would
# mean a polkit policy and an admin prompt for what is a per-user
# preference — the same reasoning that kept the whole sandbox in the user
# session instead of routing through machinectl's auth_admin_keep action.
{
  config,
  lib,
  dotsSandbox,
  ...
}:
let
  exe = lib.getExe dotsSandbox;
  busName = "org.dots.Sandbox1";
in
{
  # D-Bus activation, so the first method call starts the service and an
  # idle session never runs it. The .service file under
  # ~/.local/share/dbus-1/services is what dbus-daemon reads to know the
  # name is activatable; without it a client gets NameHasNoOwner instead of
  # a started daemon.
  #
  # SystemdService= rather than Exec= so dbus hands the start to systemd
  # and the unit's own Restart=/logging apply, instead of dbus spawning a
  # bare process it then has no further handle on.
  xdg.dataFile."dbus-1/services/${busName}.service".text = ''
    [D-BUS Service]
    Name=${busName}
    Exec=${exe} daemon
    SystemdService=dots-sandbox.service
  '';

  systemd.user.services.dots-sandbox = {
    Unit = {
      # Named for what it is. Calling this "the sandbox" would imply
      # stopping it un-confines something, and it does not.
      Description = "dots sandbox policy service (does not itself confine anything)";
      Documentation = "man:dots-sandbox(1)";
      # The session bus has to exist before a name can be claimed on it.
      Requires = [ "dbus.socket" ];
      After = [ "dbus.socket" ];
    };

    Service = {
      # Type=dbus is the point of the whole arrangement: systemd considers
      # the unit started once BusName appears on the bus, so anything
      # ordered after it can rely on the name being answerable rather than
      # merely on the process having been forked.
      Type = "dbus";
      BusName = busName;
      ExecStart = "${exe} daemon";

      # A broken policy file makes `Sandbox::new` fail at startup rather
      # than serving half-resolved answers. Restarting into the same broken
      # file forever would bury that in the journal, so back off hard and
      # let it fail visibly: the fix is editing the file, and no amount of
      # restarting reaches it.
      Restart = "on-failure";
      RestartSec = 5;
      StartLimitBurst = 3;

      # tracing writes to stderr (main.rs sets .with_writer(std::io::stderr)
      # and .without_time(), since journald stamps its own timestamps).
      StandardError = "journal";
      Environment = [ "RUST_LOG=info" ];

      # Hardening. Held to what a policy service demonstrably does not need,
      # each with its reason, rather than pasted wholesale:
      #   NoNewPrivileges  - never execs a setuid helper; it is the thing
      #                      that exists so launches do not need one.
      #   ProtectSystem=strict + ProtectHome=read-only is NOT set: this
      #                      service's entire job is writing
      #                      ~/.config/dots-sandbox/overrides.json, so
      #                      making home read-only would break SetCapability
      #                      on the first call. Named here because its
      #                      absence looks like an oversight otherwise.
      #   PrivateDevices   - opens no device node.
      #   ProtectKernelTunables/ProtectKernelModules/ProtectControlGroups
      #                    - reads no sysctl, loads no module, touches no
      #                      cgroup.
      #   RestrictRealtime, RestrictSUIDSGID, LockPersonality - none of
      #                      these surfaces is used.
      #   MemoryDenyWriteExecute is NOT set: it is cheap here (no JIT), but
      #                      zbus's async executor is a dependency whose
      #                      allocation behaviour this repo has not
      #                      verified under it, and a service that fails to
      #                      start is worse than one missing a hardening
      #                      flag. Worth revisiting with a real test.
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      # AF_UNIX for the session bus itself. No other family is ever dialed:
      # the daemon talks to D-Bus and the filesystem, nothing on a network.
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };

    # Deliberately no Install/wantedBy. The service is bus-activated, so it
    # starts on the first call and an idle session never runs it. Adding
    # wantedBy = [ "default.target" ] would start it at every login for a
    # process most sessions never speak to.
  };

  # The binary itself comes from wrap.nix's own home.packages entry; this
  # module adds no package so the two cannot disagree about which build is
  # on PATH.
  assertions = [
    {
      assertion = config.systemd.user.services ? dots-sandbox;
      message = "dots-sandbox.service failed to materialise; the Settings permissions page would silently fall back to spawning `dots-sandbox catalog` per read.";
    }
  ];
}
