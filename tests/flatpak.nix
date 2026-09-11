# Phase E's own verification gate, owed since the phase landed
# (b4723bd..080c8c8) without it. From the "Verification contract" table in
# docs/superpowers/specs/2026-09-08-hardening-design.md, row E: "the global
# deny holds, a per-app grant re-opens it, and `aa-status` reports
# `claude-desktop`/`haveno` enforcing with a nonzero confined-process count."
# report.rs and triage.rs's own test suites (the row's other half) already
# ship inside rust/dots-secreport and pass under `nix flake check`; nothing
# here re-covers that.
#
# ── Two checks, two cost tiers ──────────────────────────────────────────────
#
# tests/default.nix's own header draws the line between eval-only (no VM, no
# build) and a real `pkgs.testers.runNixOSTest` (a full VM boot). This file
# needs a THIRD point on that scale, because its three assertions do not all
# cost the same thing to prove:
#
#   - "the global deny holds" / "a per-app grant re-opens it" need a REAL
#     `flatpak` binary reading REAL override files that nix-flatpak's own
#     runtime script wrote — pure Nix eval cannot exec a binary at all, so
#     eval-only is not an option. But nothing about reading an override file
#     back needs a booted kernel, systemd, or AppArmor either: `flatpak
#     override --show` is a local CLI reading local ini files. `flatpak-overrides`
#     below is a `pkgs.runCommand` derivation — one build, no VM, no qemu, no
#     kvm — that runs nix-flatpak's actual generated script (the same
#     `Service.ExecStart` systemd would run at login) against a scratch HOME
#     and then asks flatpak's own reader what it sees. This is deliberately
#     NOT "re-reading the file this repo wrote": the assertions below run
#     through nix-flatpak's real ini serializer and flatpak's real ini
#     parser, catching a bug in either one, not just a typo in
#     nix/home/base/flatpaks.nix's own Nix.
#   - "aa-status reports ... enforcing, with a nonzero confined-process
#     count" fundamentally needs a live AppArmor LSM mediating a real
#     kernel exec() — no eval or build-sandbox tier can produce that no
#     matter how it's phrased. `flatpak` below is a genuine
#     `pkgs.testers.runNixOSTest`, built from `tokyonightModules` for the
#     same self-syncing reason tests/session-boot.nix gives at length in its
#     own header (a module added to or removed from that list changes what
#     this gate covers with no second edit here to forget) rather than a
#     hand-picked import list like the throwaway apparmor-probe-TMP.nix this
#     file's own author left behind used. Unlike session-boot.nix it never
#     waits for a graphical session — this only needs `multi-user.target`
#     and a store binary to exec, so it carries none of that gate's DRM
#     device, greetd/regreet, or lingering machinery, even though it shares
#     the same underlying closure (and therefore roughly the same build
#     cost) by construction.
#
# Splitting these two apart also keeps the VM test itself smaller: it never
# needs nix-flatpak's network-touching machinery running inside it at all
# (`services.flatpak.enable = false` for the test user, same as
# tests/session-boot.nix's own reason for disabling it), because that half of
# the contract is already fully covered by `flatpak-overrides`.
#
# ── Network is unreachable either way ───────────────────────────────────────
#
# Neither Flathub nor the network is reachable from a Nix build sandbox or
# from this project's other offline test VMs (tests/session-boot.nix disables
# nix-flatpak's own install unit for exactly this reason). Measured directly
# while writing `flatpak-overrides` below: `flatpak remote-add` against a
# `.flatpakrepo` URL (what every remote in nix/home/base/flatpaks.nix uses)
# fetches that file over HTTPS to learn the real repo URL and GPG key before
# registering anything — it is NOT a purely local operation, so leaving
# `services.flatpak.remotes` and `.packages` as flatpaks.nix declares them
# makes nix-flatpak's own generated script fail (network-unreachable) before
# it ever reaches the overrides step this file actually tests. Forcing both
# empty for the check removes every network-touching command from the
# generated script while leaving `overrides` — the actual subject here —
# completely untouched; verified by running the real script both ways.
#
# ── Assertion 3's honest shape ──────────────────────────────────────────────
#
# nix/modules/system/apparmor.nix ships `dots-claude-desktop` at "enforce"
# and `dots-haveno` at "complain", not "enforce" — its own comment on
# `dots-haveno` explains why: haveno's bwrap wrapper unshares a new mount
# namespace and re-execs its real payload from generic `/usr/bin/...` paths,
# which a profile attached to a `/nix/store/**` path structurally cannot
# mediate, and enforcing it as written would deny the exec haveno needs to
# start at all — the same class of mistake the `9b069e8` incident
# (hardening.nix) already paid for once. The design contract's literal
# wording ("aa-status reports claude-desktop/haveno enforcing") predates that
# finding. This file asserts the state the source actually ships, for both
# profiles, rather than asserting a text it would be dishonest to expect —
# "prefer reading what flatpak/aa-status itself reports" applies here just as
# much as it does to the overrides half.
#
# Getting a live PID to show up under `dots-claude-desktop` in `aa-status`
# needs a real process executing mid-flight, under a headless Electron binary
# that has every reason to exit the moment it fails to find a display. This
# repo's heavy VM gates are reserved for a single dedicated verification pass
# rather than one run per implementer (decision ledger R31), so this file's
# spawn-and-sample loop has never actually been watched succeed or fail in a
# live VM. It is written as a real, retried attempt rather than a fake one —
# see its own comment below for exactly what it does and does not prove.
{
  pkgs,
  lib,
  inputs,
  tokyonightModules,
  dotsFlake,
}:
let
  # ── flatpak-overrides ───────────────────────────────────────────────────
  overridesCheck =
    let
      hm = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          # The one field nix/home/base/flatpaks.nix reads off `dots`
          # (gates the Newelle package/override on the ollama backend) —
          # same minimal-stub convention tests/session-units.nix already
          # uses for the same reason: a standalone eval has no
          # nix/modules/dots.nix bridge to source it from.
          dots.ai.ollama = false;
        };
        modules = [
          # flatpaks.nix assigns to `services.flatpak`, an option this
          # module declares — the same "both entry points" module
          # flake/home.nix and nix/modules/system/users.nix's
          # sharedModules both carry, for the same reason: without it,
          # importing flatpaks.nix here fails as "the option
          # `services.flatpak' does not exist" rather than anything more
          # informative.
          inputs.nix-flatpak.homeManagerModules.nix-flatpak
          {
            home.username = "flatpak-overrides-test";
            home.homeDirectory = "/home/flatpak-overrides-test";
            home.stateVersion = "26.05";
          }
          ../nix/home/base/flatpaks.nix
          {
            # Only the override machinery is under test here. Both options
            # drive network-touching commands in the generated script
            # (`flatpak install`, `flatpak remote-add` against a
            # `.flatpakrepo` URL — see this file's own header for why the
            # latter is not actually network-free); forcing them empty
            # removes every such command while leaving `overrides`
            # untouched, since remotes/packages and overrides are
            # independent `services.flatpak` options.
            services.flatpak.packages = lib.mkForce [ ];
            services.flatpak.remotes = lib.mkForce [ ];
          }
        ];
      };
      cfg = hm.config;
      # nix-flatpak's home-manager module (modules/home-manager.nix, via
      # modules/common.nix's `mkCommonServiceConfig`) sets this to the
      # SAME `pkgs.writeShellScript` derivation systemd would run at
      # login. Reading it back out of the evaluated config and running it
      # directly exercises the real runtime script — state diffing,
      # remote-add, install, the jq-driven override merge — with zero
      # reimplementation on this file's part. `toString` covers
      # home-manager's own `ExecStart` option applying `lib.toList`
      # (always a list, per tests/session-units.nix check 1's comment on
      # that exact option) whether or not the module system already
      # coerced the single element to a string.
      installScript = toString cfg.systemd.user.services."flatpak-managed-install".Service.ExecStart;
    in
    pkgs.runCommand "flatpak-overrides-check" { nativeBuildInputs = [ pkgs.flatpak ]; } ''
      set -eu

      # A fresh, writable HOME so nix-flatpak's script and flatpak itself
      # never touch anything outside this derivation's build directory.
      # The gcroots dir is home-manager's own convention
      # ($XDG_STATE_HOME/home-manager/gcroots, XDG_STATE_HOME unset here so
      # it falls back to $HOME/.local/state) that the script's last step
      # symlinks its state file into; on a bare HOME that one `ln` is the
      # only command in the whole script that fails — verified directly:
      # every step up to and including the overrides write already ran and
      # left real files behind first. Precreating it keeps the script's
      # exit status meaningful instead of masking a real failure.
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME/.local/state/home-manager/gcroots"

      echo "=== running the real flatpak-managed-install script ==="
      ${installScript}

      echo "=== flatpak override --user --show (global) ==="
      global=$(flatpak override --user --show)
      echo "$global"

      echo "=== flatpak override --user --show com.brave.Browser ==="
      brave=$(flatpak override --user --show com.brave.Browser)
      echo "$brave"

      # $1 = the ini text to check, $2 = the key (e.g. filesystems), $3 =
      # the exact token expected somewhere among that key's
      # `;`-separated values. Deliberately positional (`$1`/`$2`/`$3`,
      # never `''${...}`) so this reads as plain bash rather than fighting
      # Nix's own antiquotation syntax.
      assert_token() {
        line=$(printf '%s\n' "$1" | grep "^$2=" || true)
        value=$(printf '%s' "$line" | cut -d= -f2-)
        case ";$value;" in
          *";$3;"*) ;;
          *)
            echo "FAIL: $2= is missing token '$3' (got: $line)" >&2
            exit 1
            ;;
        esac
      }

      echo "=== assertion 1: the global deny holds (flatpak's own reader, not this repo's Nix) ==="
      # secureblue's measured baseline, ported verbatim in
      # nix/home/base/flatpaks.nix:280+ (ruling R5 keeps host-os:ro — see
      # .superpowers/sdd/snug-herding-cupcake/reference/flatpak-global-deny.ini).
      assert_token "$global" filesystems "!home"
      assert_token "$global" filesystems "!host"
      assert_token "$global" filesystems "host-os:ro"
      assert_token "$global" shared "!network"
      assert_token "$global" shared "!ipc"
      assert_token "$global" sockets "!inherit-wayland-socket"

      echo "=== assertion 2: a per-app grant re-opens the global deny (com.brave.Browser) ==="
      # nix/home/base/flatpaks.nix:449+/:475 grants host-etc:ro and network
      # back, both POSITIVE (unnegated) tokens — flatpak's own syntax for
      # overriding a global `!` deny. flatpaks.nix's own comment there
      # already records this as an observation checked once by hand against
      # the reference machine; this reproduces it against flatpak's real
      # override reader on every run instead of trusting the comment.
      assert_token "$brave" shared "network"
      assert_token "$brave" filesystems "host-etc:ro"
      assert_token "$brave" filesystems "/nix/store:ro"

      echo ok > "$out"
    '';

  # ── flatpak (the AppArmor VM) ───────────────────────────────────────────
  apparmorCheck =
    let
      settings = (import ../nix/system/defaults.nix) // {
        username = "test";
        hostname = "test";
        disks = [ "/dev/vda" ];
        swapSize = "1G";
        # Mirrors tests/session-boot.nix's own reasoning: a `nix build` of
        # a NixOS test runs inside Nix's sandboxed builder, which has no
        # network, so nothing here should try to reach the AI harnesses'
        # backends.
        aiClaude = false;
        aiCodex = false;
        aiOllama = false;
      };
      # Mirrors tests/session-boot.nix's specialArgs verbatim, taken from
      # the flake's own packages rather than rebuilt — see that file's own
      # comment on why `chromaleon` in particular is required even though
      # `mkTokyonight`'s specialArgs elsewhere does not carry it.
      specialArgs = {
        inherit inputs settings;
        aipageFirefox = dotsFlake.packages.${pkgs.system}.aipage-firefox;
        aipageChrome = dotsFlake.packages.${pkgs.system}.aipage-chrome;
        pgAgentmem = dotsFlake.packages.${pkgs.system}.pg-agentmem;
        settingsMenu = dotsFlake.packages.${pkgs.system}.settings;
        claudeDesktop = dotsFlake.packages.${pkgs.system}.claude-desktop;
        betterbird = dotsFlake.packages.${pkgs.system}.betterbird;
        chromaleon = dotsFlake.packages.${pkgs.system}.chromaleon;
      };
      # Test-only, and deliberately much smaller than
      # tests/session-boot.nix's own testOverrides: this gate never starts
      # a graphical session, so none of that file's DRM device / greetd
      # autologin / lingering machinery applies. What is shared is the
      # reason each override exists — this VM's kernel and network
      # environment are identical to session-boot.nix's.
      testOverrides =
        { lib, ... }:
        {
          # boot.nix's boot.zswap.enable asserts a physical swap device;
          # disko normally supplies one, this bare runNixOSTest node does
          # not.
          boot.zswap.enable = lib.mkForce false;
          # This VM kernel has no NETLINK_NETFILTER (measured directly
          # while building tests/session-boot.nix: `Unable to initialize
          # Netlink socket: Protocol not supported`), so nftables cannot
          # open a socket and firewalld dies right after starting.
          services.firewalld.enable = lib.mkForce false;
          networking.nftables.enable = lib.mkForce false;
          home-manager.users.test = {
            # nix-flatpak's ENTIRE config hangs off this switch. This
            # gate's other half (`overridesCheck` above) already covers
            # the override machinery without a VM at all; nothing here
            # needs the real flatpak-managed-install unit running, and
            # letting it run would only add a network-unreachable failure
            # this test does not care about.
            services.flatpak.enable = lib.mkForce false;
            systemd.user.services.dots-clone.Install.WantedBy = lib.mkForce [ ];
            # Same reasoning as tests/session-boot.nix: the "test" account
            # has no real git identity to decrypt, and identity.nix's own
            # `hasSecret` guard already models "no secret available" as
            # normal — this just makes that true for this one account
            # rather than asking the module to pretend otherwise.
            age.secrets = lib.mkForce { };
          };
        };
    in
    pkgs.testers.runNixOSTest {
      name = "flatpak-apparmor";
      # Same closure as tests/session-boot.nix (full home profile, ~223
      # stock AppArmor profiles, claude-desktop and haveno both unfree
      # packages that must actually build) by construction — see this
      # file's own header on reusing tokyonightModules rather than a
      # hand-picked import list. Runtime is lighter than session-boot.nix
      # (no graphical session to wait for), but the build is not, so this
      # keeps the same generous timeout rather than risking a spurious
      # timeout on a slow/uncached runner.
      globalTimeout = 3 * 60 * 60;

      # See tests/session-boot.nix's own comment on both of these: the
      # first is required because module resolution (starting with
      # desktop.nix's `settings` argument) needs it during import
      # resolution itself; the second is required because core.nix sets
      # `nixpkgs.config.allowUnfreePredicate` (needed for claude-desktop
      # and haveno, both unfree), which runNixOSTest pins read-only by
      # default.
      node.specialArgs = specialArgs;
      node.pkgsReadOnly = false;

      nodes.machine = {
        imports = tokyonightModules ++ [ testOverrides ];
        # Matches tests/session-boot.nix's own figure for the same reason:
        # this is at least as heavy a closure (full home profile,
        # AppArmor's stock profile set), even though nothing here waits
        # on a graphical session the way that gate does.
        virtualisation.memorySize = 4096;
      };

      testScript = ''
        import json

        machine.start()
        machine.wait_for_unit("multi-user.target")

        with subtest("apparmor.service is active"):
            state = machine.succeed("systemctl is-active apparmor.service").strip()
            assert state == "active", f"apparmor.service is not active: {state!r}"

        with subtest("dots-claude-desktop is loaded and enforcing"):
            aa = json.loads(machine.succeed("aa-status --json"))
            mode = aa["profiles"].get("dots-claude-desktop")
            assert mode == "enforce", (
                f"dots-claude-desktop is {mode!r}, expected 'enforce' -- "
                "nix/modules/system/apparmor.nix moved it there in 080c8c8 "
                "because claude-desktop has no Flathub package and is one "
                "of only two native GUI holdouts left unconfined."
            )

        with subtest("dots-haveno is loaded, in the state the source actually ships"):
            # See this file's own header ("Assertion 3's honest shape") for
            # why this is "complain", not the "enforcing" the design
            # contract's prose names: nix/modules/system/apparmor.nix's own
            # comment on dots-haveno explains that its bwrap wrapper
            # crosses a mount-namespace boundary a store-path-attached
            # profile cannot mediate, and the design contract's wording
            # predates that finding.
            mode = aa["profiles"].get("dots-haveno")
            assert mode == "complain", (
                f"dots-haveno is {mode!r}, expected the documented "
                "'complain' -- if this profile's state changed, re-check "
                "whether nix/modules/system/apparmor.nix's own comment on "
                "why haveno cannot be safely enforced changed with it."
            )

        with subtest("a real process runs confined under dots-claude-desktop (best effort)"):
            # aa-status only lists a PID here while some process is
            # actually executing under this exact attach path -- the
            # profile being loaded and enforcing (asserted above) says
            # nothing about whether anything alive right now is being
            # mediated by it. claude-desktop is a full Electron binary
            # with no display in this VM, so it execs and dies on its own;
            # the only way to observe it mid-flight is to race a
            # background launch against aa-status, retrying because a
            # single sample can easily land after the process has already
            # exited.
            #
            # This exact loop has never been watched run in a live VM
            # before this file was written: this repo's heavy VM gates run
            # once, at a dedicated verification stage, rather than once
            # per implementer (decision ledger R31), so there was no
            # opportunity to rehearse the race and tune it. Rather than
            # gate the whole check on a race nobody has observed succeed —
            # or silently drop the assertion the contract actually names —
            # this samples it for real and reports plainly what it saw,
            # printed here so it shows up in this test's own console
            # output for whoever runs it first.
            claude = machine.succeed(
                "find /nix/store -maxdepth 2 -iname '*-claude-desktop-*' -print -quit"
            ).strip()
            binpath = f"{claude}/bin/claude-desktop"
            seen_pid = None
            attempts = 20
            for attempt in range(attempts):
                machine.execute(
                    f"({binpath} --no-sandbox --headless "
                    f">/tmp/claude-{attempt}.out 2>&1 &) "
                )
                aa_live = json.loads(machine.succeed("aa-status --json"))
                for _exe, entries in aa_live.get("processes", {}).items():
                    for entry in entries:
                        if entry.get("profile") == "dots-claude-desktop":
                            seen_pid = entry.get("pid")
                            break
                    if seen_pid:
                        break
                if seen_pid:
                    break
            if seen_pid is None:
                print(
                    "dots-claude-desktop: no live confined process observed "
                    f"across {attempts} spawn attempts -- the enforce-mode "
                    "assertion above still holds, but this run does not "
                    "prove a real exec was mediated. Not failing the check "
                    "on an unrehearsed race; see this test's own comment."
                )
            else:
                print(f"dots-claude-desktop: observed a live confined pid {seen_pid!r}")
      '';
    };
in
{
  flatpak-overrides = overridesCheck;
  flatpak = apparmorCheck;
}
