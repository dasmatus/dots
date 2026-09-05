# The per-app sandbox's central, previously-unsettled design question: does
# `machinectl --user bind` actually work against a user-scope machine? A NixOS
# VM test, not an eval-only check (contrast tests/sandbox-machined.nix, which
# only proves the home-manager module *wires units*) — the property under
# test here is runtime behaviour that needs `systemd-nsresourced.service`
# actually running, a real unprivileged `systemd-nspawn --user` machine
# actually registering with a real `systemd-machined --user`, and a real
# `machinectl` invocation actually landing a bind mount inside it. None of
# that can be produced by a Nix build sandbox (no user namespaces, no
# per-session D-Bus), and it could not be settled on the host either: enabling
# `systemd-nsresourced` needs a `nixos-rebuild switch` nobody has authorised
# for this task. A VM has no such constraint, so it is where this gets
# answered.
#
# Modelled on tests/limine-home.nix for weight: one `pkgs.testers.runNixOSTest`
# node, no disko, no `nixos-install`, no facter.json. This must not grow into
# a second `iso-boot`.
#
# Scope: the CONTAINER tier only (`systemd-nspawn`, via `GrantKind::Path` /
# `machinectl ... bind`). The `vm` tier's `bind-volume`/`unbind-volume` pair
# (rust/dots-sandbox/src/grants.rs) is not exercised here — nested KVM is
# available on this machine, but `man machinectl` (systemd 261, confirmed
# against the exact systemd this flake's pinned nixpkgs ships) says
# `bind-volume` is "currently only supported for systemd-vmspawn machines
# that expose an io.systemd.MachineInstance control socket", a materially
# bigger build (a bootable VM kernel + firmware descriptor + virtiofsd
# wiring) for a question this file does not need to ask. Narrowing to the
# container tier is the brief's own explicit fallback for exactly this case.
#
# ---------------------------------------------------------------------------
# What actually happened running this
# ---------------------------------------------------------------------------
# Getting this far already surfaced and fixed two real, previously-unverified
# bugs (see nix/home/sandbox/machined.nix and nix/modules/system/sandbox-host.nix
# for the full account, and this task's report for the reproduction):
#
#   1. machined.nix's `dbus-org.freedesktop.machine1.service` alias was wired
#      as a plain `xdg.configFile.<name>.source` pointing into the Nix store.
#      systemd's own alias detection (`unit_file_resolve_symlink()`,
#      src/shared/unit-file.c) only recognizes a fragment as an alias when
#      its one-hop, non-followed symlink target still resolves INSIDE a
#      registered unit search directory; a Nix store path never does. Every
#      `xdg.configFile` value is therefore loaded as an independent unit
#      instead of an alias, and since `systemd-machined.service`'s own
#      `[Service]` section sets `BusName=org.freedesktop.machine1`, the
#      result was two separate units both claiming that bus name --
#      `systemd[…]: Two services allocated for the same bus name
#      org.freedesktop.machine1, refusing operation` -- which fails
#      `machinectl --user` outright, every subcommand, before a single
#      container is even involved. Fixed with a `home.activation` step that
#      writes the real, same-directory relative symlink upstream ships
#      (`ln -sfn systemd-machined.service …`), which is what actually lands
#      inside the search path and gets recognized.
#
#   2. `systemd-mountfsd` turned out to be a second, sibling prerequisite
#      alongside `systemd-nsresourced`: an unprivileged `--ephemeral` mount
#      over a plain directory needs it too ("Failed to connect to mountfsd").
#      Added to nix/modules/system/sandbox-host.nix next to nsresourced.
#
# With both of those fixed, the experiment reaches a THIRD blocker that this
# task cannot fix from inside this repo: `systemd-nspawn --private-users=managed`
# (what rust/dots-sandbox's `container_argv` always emits) asks nsresourced to
# allocate a 64K-uid managed range, and nsresourced *unconditionally* refuses
# to hand one out unless it can first install a BPF-LSM lockdown program over
# it (src/nsresourced/nsresourcework.c, three call sites, all
# `if (!c->bpf) { r = userns_restrict_install(...); if (r < 0) return r; }` --
# no config knob, no CLI flag skips this). `userns_restrict_install()`'s real
# body is compiled in only `#if HAVE_VMLINUX_H` (src/nsresourced/userns-restrict.c)
# -- i.e. only when systemd's OWN build could generate a kernel-BTF-derived
# `vmlinux.h` (an eBPF CO-RE skeleton header) at build time. nixpkgs' systemd
# derivation does not attempt this, and Nix's sandboxed builder has no live
# kernel BTF (`/sys/kernel/btf/vmlinux`) to derive it from even if it tried.
# Without it, `userns_restrict_install()` is a stub that unconditionally
# returns `EOPNOTSUPP` ("User Namespace Restriction BPF support disabled.") --
# reproduced here as `systemd-nsresourced[…]: Not setting up BPF subsystem, as
# functionality has been disabled at compile time.` at nsresourced's own
# startup, then `Failed to allocate user namespace with 64K users: Operation
# not supported` the moment anything asks it for a managed range.
#
# The practical upshot: `systemd-nspawn --private-users=managed` cannot start
# AT ALL on this or any standard nixpkgs-built NixOS system -- not "the host
# hasn't switched yet" (this VM has switched, freshly, to exactly the config
# under test), but a nixpkgs-wide packaging characteristic outside this
# repo's Nix modules to fix. That is one layer BEFORE the original open
# question ("does a running user-scope machine accept `bind`?") rather than
# an answer to it -- see the "start a long-lived container" subtest below,
# and this task's report, for the plain verdict.
#
# What still runs and passes despite that, because they do not depend on a
# container actually starting: user-scope `machine1` being reachable with
# zero authentication at all (the fix above), the headless `ask` capability
# denying immediately rather than blocking on `PROMPT_TIMEOUT` (assertion 4,
# checked via the audit log rather than the launch's exit code, precisely
# because that exit code is now entangled with the unrelated blocker above),
# and `DOTS_SANDBOX=0` bypassing the sandbox before `dots-sandbox` is ever
# invoked (assertion 5, entirely decoupled from nsresourced).
{
  pkgs,
  lib,
  inputs,
  dotsFlake,
}:
let
  testUser = "sandboxer";
  testUid = 1500;

  # A fully self-contained, statically-linked container rootfs. This is not
  # a convenience — it is required by the very capability set under test:
  # `nix-daemon` (the only capability that would bind `/nix/store` into the
  # container, see argv.rs's `container_argv`) is deliberately withheld from
  # every app policy below, so a dynamically-linked payload would have no
  # loader and no libc to run against. `pkgsStatic.busybox` needs neither.
  containerRootfs = pkgs.runCommand "dots-sandbox-test-rootfs" { } ''
    mkdir -p $out/usr/lib $out/bin $out/proc $out/sys $out/dev $out/tmp $out/mnt $out/root
    # systemd-nspawn's own safety check (man systemd-nspawn) refuses to boot
    # a directory tree with neither file present.
    echo 'NAME=dots-sandbox-test' > $out/usr/lib/os-release
    install -Dm755 ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
    for applet in sh cat ls sleep true false mkdir test env; do
      ln -s busybox $out/bin/$applet
    done
  '';

  # A policy catalog scoped to this test alone -- deliberately NOT
  # nix/data/sandbox-policy.json, so a change here can never affect the real
  # app catalog and vice versa.
  #   - grant-target: the bind experiment (assertions 1-3).  No capabilities
  #     at all, so the ONLY things bound into it are the ephemeral rootfs and
  #     the always-present grant-share mount -- anything else visible inside
  #     would be a real leak, not a false positive from an overly generous
  #     policy.
  #   - networked-target: the same, plus `net: allow`, so the D-Bus/Hyprland
  #     absence check (assertion 3) is not just proven for one capability
  #     shape.
  #   - ask-target: one `ask` capability, for the headless-prompt experiment
  #     (assertion 4).
  testPolicy = pkgs.writeText "dots-sandbox-test-policy.json" (
    builtins.toJSON {
      version = 1;
      denyPaths = [ ];
      apps = {
        grant-target = {
          tier = "container";
          caps = { };
        };
        networked-target = {
          tier = "container";
          caps = {
            net = "allow";
          };
        };
        ask-target = {
          tier = "container";
          caps = {
            net = "ask";
          };
        };
      };
    }
  );

  dotsSandbox = dotsFlake.packages.${pkgs.system}.dots-sandbox;
  # The real `nix run .#clean` wrapper (flake/apps.nix's `mkSandboxedApp`) --
  # not a hand-copied twin -- so assertion 5 pins the actual DOTS_SANDBOX=0
  # bypass shipped to users, not a reimplementation of what it is believed
  # to do.
  cleanWrapper = dotsFlake.apps.${pkgs.system}.clean.program;
in
pkgs.testers.runNixOSTest {
  name = "sandbox";

  nodes.machine =
    { ... }:
    {
      imports = [
        # System scope: enables systemd-nsresourced + systemd-mountfsd, and
        # packages virtiofsd. Imported directly rather than assumed -- the
        # whole point of this test is that the HOST module is inert until a
        # switch nobody has run, so the VM must be the one to turn it on.
        ../nix/modules/system/sandbox-host.nix
        inputs.home-manager.nixosModules.home-manager
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };

      users.users.${testUser} = {
        isNormalUser = true;
        uid = testUid;
      };

      # The real production module (nix/home/sandbox/machined.nix), applied
      # through home-manager exactly as nix/modules/system/users.nix wires it
      # for the real primary user -- not a hand-rolled set of
      # systemd.user.sockets/services standing in for it. If machined.nix
      # itself regresses, this test fails alongside tests/sandbox-machined.nix
      # rather than past it.
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        users.${testUser} = {
          imports = [ ../nix/home/sandbox/machined.nix ];
          home.stateVersion = "26.05";
        };
      };

      environment.systemPackages = [ dotsSandbox ];
      environment.etc."dots-sandbox-test-policy.json".source = testPolicy;
      environment.etc."dots-sandbox-test-rootfs".source = containerRootfs;
      environment.etc."dots-clean-wrapper".source = cleanWrapper;
    };

  testScript = ''
    import json
    import time

    USER = "${testUser}"
    UID = ${toString testUid}
    RUNTIME_DIR = f"/run/user/{UID}"
    DOTS_SANDBOX = "/run/current-system/sw/bin/dots-sandbox"
    POLICY = "/etc/dots-sandbox-test-policy.json"
    ROOTFS = "/etc/dots-sandbox-test-rootfs"
    CLEAN_WRAPPER = "/etc/dots-clean-wrapper"
    AUDIT_LOG = f"/home/{USER}/.local/state/dots-sandbox/audit.jsonl"

    def as_user(cmd):
        # Every invocation is explicit about its environment rather than
        # relying on whatever `runuser` happens to inherit -- the same
        # discipline tests/limine-home.nix uses for its own `env HOME=...`
        # probes.
        return (
            f"runuser -u {USER} -- env XDG_RUNTIME_DIR={RUNTIME_DIR} "
            f"HOME=/home/{USER} DOTS_SANDBOX_DEFAULTS={POLICY} "
            f"DOTS_SANDBOX_CONTAINER_ROOTFS={ROOTFS} {cmd}"
        )

    def start_container(app_id, program_argv, log_name):
        # `setsid ... &`: fully detaches from the backdoor shell's own
        # session so the sandboxed machine outlives the command that
        # launched it -- the machine is meant to stay up until a later
        # subtest explicitly tears it down.
        machine.succeed(as_user(
            f"setsid {DOTS_SANDBOX} run --app {app_id} -- {program_argv} "
            f"< /dev/null > /tmp/{log_name}.log 2>&1 &"
        ))

    def list_machines():
        out = machine.succeed(as_user("machinectl --user list --output=json")).strip()
        return json.loads(out)

    def wait_for_machine(name_hint, timeout=30):
        # The exact field name `machinectl --user list --output=json` uses
        # is not something this crate has ever observed (grants.rs's own doc
        # comment says as much) -- match schema-agnostically against the
        # whole serialized entry rather than guess a key, and print every
        # entry seen so the real schema ends up in this test's own log.
        deadline = time.time() + timeout
        last_seen = None
        while time.time() < deadline:
            machines = list_machines()
            last_seen = machines
            for entry in machines:
                print("machinectl --user list entry:", entry)
                if name_hint in json.dumps(entry):
                    name = entry.get("machine") or entry.get("name")
                    assert name, f"could not find a name-shaped key in {entry!r}"
                    return name
            time.sleep(1)
        raise Exception(
            f"no machine matching {name_hint!r} registered within {timeout}s; "
            f"last `machinectl --user list` saw: {last_seen!r}"
        )

    def leader_pid(machine_name):
        out = machine.succeed(
            as_user(f"machinectl --user show {machine_name} --property=Leader --value")
        ).strip()
        return int(out)

    def path_exists_in(pid, path):
        status, _ = machine.execute(f"nsenter --target {pid} --mount -- test -e {path}")
        return status == 0

    def read_in(pid, path):
        return machine.succeed(f"nsenter --target {pid} --mount -- cat {path}")

    def terminate(machine_name):
        machine.succeed(as_user(f"machinectl --user terminate {machine_name}"))

    def diagnose_and_fail_if_managed_userns_is_structurally_unavailable(log_name):
        # See this file's own header ("What actually happened running
        # this") for the full causal chain. Checked explicitly, rather than
        # left to time out inside `wait_for_machine`, so a red build names
        # the real cause immediately instead of "no machine appeared".
        launch_log = machine.succeed(f"cat /tmp/{log_name}.log 2>&1 || true")
        nsresourced_log = machine.succeed(
            "journalctl -q --no-pager -b -u systemd-nsresourced.service 2>&1 | tail -20"
        )
        bpf_compiled_out = "disabled at compile time" in nsresourced_log
        userns_alloc_failed = (
            "Failed to allocate user namespace" in launch_log
            and "Operation not supported" in launch_log
        )
        if bpf_compiled_out and userns_alloc_failed:
            raise Exception(
                "BLOCKED ONE LAYER BEFORE THE BIND QUESTION.\n\n"
                f"systemd-nsresourced (system journal):\n{nsresourced_log.strip()}\n\n"
                f"the sandboxed launch itself:\n{launch_log.strip()}\n\n"
                "systemd-nspawn --private-users=managed (what container_argv "
                "always emits) cannot start on this systemd build: nsresourced "
                "refuses every managed-range allocation without first "
                "installing a BPF-LSM lockdown program over it, and that "
                "program is compiled in only #if HAVE_VMLINUX_H -- which "
                "needs kernel-BTF-derived vmlinux.h at systemd's OWN build "
                "time, something nixpkgs' systemd derivation does not "
                "attempt and Nix's sandboxed builder cannot provide (no live "
                "kernel BTF inside the build sandbox). See this file's header "
                "comment and this task's report for the full trace."
            )

    machine.wait_for_unit("multi-user.target")

    with subtest("user-scope machine1 is reachable with zero authentication"):
        # Starting the per-uid manager directly -- no real login, no
        # lingering -- is the standard way to exercise a `--user` service in
        # a test VM. `user-runtime-dir@.service`, a dependency of
        # `user@.service`, is what actually creates /run/user/<uid> and the
        # session bus socket machined.nix's own header describes.
        machine.succeed(f"systemctl start user@{UID}.service")
        machine.wait_until_succeeds(f"test -S {RUNTIME_DIR}/bus")
        # The cheapest possible probe (live_grant.rs uses the identical one
        # on the host, where it fails): no machine needs to exist yet, only
        # machined itself needs to be bus-activatable. This is the exact
        # step that caught the machined.nix alias bug -- see this file's
        # header.
        machine.succeed(as_user("machinectl --user list"))

    with subtest("DOTS_SANDBOX=0 bypasses the sandbox entirely, even against a policy that would otherwise fail"):
        # Independent of every other assertion here: the bypass lives in the
        # flake/apps.nix wrapper, before dots-sandbox is ever exec'd, so it
        # cannot be affected by whether a real sandboxed launch can succeed.
        machine.succeed("mkdir -p /tmp/scratch && touch /tmp/scratch/flake.nix")

        # Baseline: our test policy has no "clean" app id at all (it is a
        # scratch catalog for the other assertions), so without the bypass
        # the wrapper's own `exec dots-sandbox run --app clean ...` must
        # fail with an unknown-app diagnostic. This is what proves the
        # bypass path below is actually doing something, not just always
        # succeeding regardless of DOTS_SANDBOX.
        status, out = machine.execute(
            f"cd /tmp/scratch && env DOTS_SANDBOX_DEFAULTS={POLICY} {CLEAN_WRAPPER}"
        )
        assert status != 0, (
            f"expected the unwrapped run to fail against a policy with no "
            f"'clean' entry, got exit 0: {out!r}"
        )

        # With the bypass: mkSandboxedApp's own comment is explicit that
        # this check happens before dots-sandbox is ever invoked, precisely
        # so the escape hatch still works when dots-sandbox itself -- or, as
        # here, its policy -- is broken.
        out = machine.succeed(
            f"cd /tmp/scratch && env DOTS_SANDBOX=0 DOTS_SANDBOX_DEFAULTS={POLICY} {CLEAN_WRAPPER}"
        )
        assert "cleaned build" in out, f"expected the real clean script to run, got: {out!r}"

    with subtest("the headless `ask` capability denies immediately, under a hard timeout"):
        # No WAYLAND_DISPLAY (this VM runs no compositor) and stdin
        # explicitly redirected from /dev/null (so `is_terminal()` cannot
        # accidentally see the test driver's own backdoor connection as a
        # TTY) -- broker::resolve_prompt's `DeniedNoPromptChannel` branch is
        # reached with neither channel available, which returns
        # synchronously. `timeout 10` is the safety net: if a future
        # regression reintroduces a real wait (tty_prompt's own
        # PROMPT_TIMEOUT is 20s), this test fails fast via `timeout`'s
        # SIGKILL instead of hanging the whole VM build.
        #
        # The exit code of the overall `dots-sandbox run` is NOT asserted
        # here: broker::decide runs, and gets logged, before argv::spawn_argv
        # / the actual systemd-nspawn spawn even happens (launch.rs), so the
        # capability decision this subtest cares about is already final by
        # the time (and regardless of whether) the sandboxed launch itself
        # goes on to fail for the unrelated reason this file's header
        # documents. Asserting the audit log directly keeps this assertion
        # about what it claims to be about.
        machine.succeed(f"rm -f {AUDIT_LOG}")
        start = time.time()
        status, out = machine.execute(
            as_user(f"timeout 10 {DOTS_SANDBOX} run --app ask-target --interactive -- /bin/sh -c 'echo ran' < /dev/null")
        )
        elapsed = time.time() - start
        print(f"ask path returned in {elapsed:.2f}s, exit={status}, output={out!r}")
        assert elapsed < 5, (
            f"the headless ask path took {elapsed:.2f}s -- it must deny immediately, "
            "not wait anywhere near PROMPT_TIMEOUT"
        )
        audit_lines = machine.succeed(f"cat {AUDIT_LOG}").strip().splitlines()
        net_events = [
            json.loads(line) for line in audit_lines if json.loads(line).get("capability") == "net"
        ]
        assert net_events, f"no audit event for the 'net' capability was logged at all: {audit_lines!r}"
        assert net_events[-1]["outcome"] == "denied_no_prompt_channel", (
            f"expected the headless ask to resolve to denied_no_prompt_channel, "
            f"got {net_events[-1]!r}"
        )

    with subtest("start a long-lived container in the user scope and confirm registration"):
        start_container("grant-target", "/bin/sh -c 'sleep 300'", "grant-target")
        time.sleep(3)
        diagnose_and_fail_if_managed_userns_is_structurally_unavailable("grant-target")
        machine_name = wait_for_machine("dots-grant-target")
        print(f"registered machine: {machine_name}")

    with subtest("plant the grant source on the host"):
        machine.succeed(
            "mkdir -p /root/grant-src && echo GRANT-OK-9f3a1c > /root/grant-src/marker.txt"
        )

    with subtest("THE EXPERIMENT: machinectl --user bind against a user-scope machine"):
        bind_out = machine.succeed(
            as_user(f"machinectl --user bind --mkdir {machine_name} /root/grant-src /mnt/granted 2>&1")
        )
        print("machinectl --user bind output:", repr(bind_out))

    with subtest("the bound content is visible inside the running machine"):
        pid = leader_pid(machine_name)
        seen = read_in(pid, "/mnt/granted/marker.txt").strip()
        assert seen == "GRANT-OK-9f3a1c", f"expected the granted marker, got {seen!r}"

    with subtest("a planted secret outside every granted path stays invisible"):
        machine.succeed(f"mkdir -p /home/{USER}/.ssh && echo SUPER-SECRET > /home/{USER}/.ssh/fake-key")
        assert not path_exists_in(pid, f"/home/{USER}/.ssh/fake-key"), (
            "a file outside every granted path leaked into the sandboxed container"
        )

    with subtest("the session D-Bus socket and Hyprland's IPC socket stay unreachable (grant-target profile)"):
        assert not path_exists_in(pid, f"{RUNTIME_DIR}/bus"), (
            "the session D-Bus socket leaked into the sandbox -- systemd --user "
            "would be able to start anything asked of it from inside"
        )
        # No Hyprland runs in this headless VM; stand in for its IPC socket
        # at the well-known path shape ($XDG_RUNTIME_DIR/hypr/<signature>/
        # .socket.sock) so the check is against a real path, not an
        # imagined one.
        machine.succeed(f"mkdir -p {RUNTIME_DIR}/hypr/fake-sig && touch {RUNTIME_DIR}/hypr/fake-sig/.socket.sock")
        assert not path_exists_in(pid, f"{RUNTIME_DIR}/hypr/fake-sig/.socket.sock"), (
            "Hyprland's IPC socket path leaked into the sandbox -- "
            "hyprctl dispatch exec would be reachable from inside"
        )

    with subtest("a second, networked profile keeps the same two sockets unreachable"):
        start_container("networked-target", "/bin/sh -c 'sleep 60'", "networked-target")
        net_name = wait_for_machine("dots-networked-target")
        net_pid = leader_pid(net_name)
        assert not path_exists_in(net_pid, f"{RUNTIME_DIR}/bus"), (
            "the session D-Bus socket leaked into the networked-capability profile"
        )
        assert not path_exists_in(net_pid, f"{RUNTIME_DIR}/hypr/fake-sig/.socket.sock"), (
            "Hyprland's IPC socket path leaked into the networked-capability profile"
        )
        terminate(net_name)

    with subtest("plain `machinectl bind` has no live unbind -- restarting the machine is the documented fallback"):
        # grants.rs is explicit that a plain path grant is one-way: `bind`
        # has no matching `unbind` (only `bind-volume`/`unbind-volume` do,
        # and those apply only to the `vm` tier -- see this file's header).
        # `GrantError::PathRevokeUnsupported`'s own help text says what the
        # real fallback is: "restart the sandbox to drop this grant". This
        # proves exactly that fallback, not a live unbind that does not
        # exist: terminate the machine that has the grant, start a fresh one
        # under the identical policy, and confirm the fresh instance never
        # sees it -- the grant lived exactly as long as the machine did.
        terminate(machine_name)

        def machine_gone(name):
            status, _ = machine.execute(as_user(f"machinectl --user show {name} --property=Leader --value"))
            return status != 0

        deadline = time.time() + 30
        while time.time() < deadline and not machine_gone(machine_name):
            time.sleep(1)
        assert machine_gone(machine_name), f"{machine_name} was still registered after terminate"

        start_container("grant-target", "/bin/sh -c 'sleep 60'", "grant-target-2")
        fresh_name = wait_for_machine("dots-grant-target")
        fresh_pid = leader_pid(fresh_name)
        assert not path_exists_in(fresh_pid, "/mnt/granted"), (
            "the grant survived into a freshly started machine -- a plain bind "
            "must not outlive the machine it was bound into"
        )
        terminate(fresh_name)
  '';
}
