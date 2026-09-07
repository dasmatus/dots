# Regression guard for nix/home/sandbox/machined.nix. Eval-only, in the
# style of tests/session-units.nix and tests/proton-calendar.nix: a
# standalone `home-manager.lib.homeManagerConfiguration` read back through
# `.config` and checked with asserts — no VM, no activation.
#
# What this exists to catch: "an inert module that quietly wires nothing"
# (machined.nix's own header) is exactly the failure mode a home-manager
# module has the most room to hide — the switch nobody runs in CI would be
# the first place anyone noticed. This forces the same evaluation a switch
# would do, minus activation.
{
  pkgs,
  lib,
  inputs,
  dotsFlake,
}:
let
  hm = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    # nix/home/sandbox/machined.nix destructures `dotsSandbox` (it puts the
    # binary in home.packages and names it in the generated units), so the
    # module cannot evaluate without it. Taken from the flake's own packages
    # rather than rebuilt, which is what nix/modules/system/users.nix and
    # flake/home.nix both do — the test then exercises the same derivation
    # production uses.
    #
    # This argument was missing until `nix flake check` became runnable on a
    # bare checkout: while nix/data/settings.nix was a symlink into
    # /var/lib/dots, pure eval refused the whole flake, so nothing ever forced
    # this test and it failed with "attribute 'dotsSandbox' missing" the first
    # time anything did.
    extraSpecialArgs = {
      dotsSandbox = dotsFlake.packages.${pkgs.system}.dots-sandbox;
    };
    modules = [
      {
        home.username = "sandbox-machined-test";
        home.homeDirectory = "/home/sandbox-machined-test";
        home.stateVersion = "26.05";
      }
      ../nix/home/sandbox/machined.nix
    ];
  };
  cfg = hm.config;
  files = cfg.xdg.configFile;

  # --- 1. Every unit the design needs is actually placed. -------------------
  expectedPresent = [
    "systemd/user/systemd-machined.service"
    "systemd/user/systemd-machined.socket"
    "systemd/user/dbus-org.freedesktop.machine1.service"
    "systemd/user/machine.slice"
    # The socket's enablement symlink — proves this is socket-activated
    # (present, wanted-by sockets.target) rather than merely present.
    "systemd/user/sockets.target.wants/systemd-machined.socket"
  ];
  missing = builtins.filter (p: !(files ? ${p})) expectedPresent;
  missingMsg = lib.concatStringsSep ", " missing;

  # --- 2. Every one of those is a REFERENCE into pkgs.systemd, never .text. -
  # The whole point of machined.nix's design (see its header) is that a
  # systemd bump carries these units' content automatically. A `.text`
  # entry, or a `.source` pointing anywhere other than this exact
  # `pkgs.systemd` derivation, would be exactly the transcription drift the
  # module exists to avoid.
  systemdStore = toString pkgs.systemd;
  notAReference = builtins.filter (
    p:
    let
      entry = files.${p} or { };
      src = toString (entry.source or "");
    in
    (entry.text or null) != null || !(lib.hasPrefix systemdStore src)
  ) expectedPresent;
  notAReferenceMsg = lib.concatStringsSep ", " notAReference;

  # --- 3. The unused template units / machines.target stay unwired. --------
  # Wiring `systemd-nspawn@`/`systemd-vmspawn@` (user templates) or
  # `machines.target` would be dead configuration for a launcher that
  # invokes the nspawn/vmspawn binaries directly — see machined.nix's own
  # header for why. This catches an accidental re-introduction.
  unwantedPaths = [
    "systemd/user/systemd-nspawn@.service"
    "systemd/user/systemd-vmspawn@.service"
    "systemd/user/machines.target"
  ];
  unwantedPresent = builtins.filter (p: files ? ${p}) unwantedPaths;
  unwantedPresentMsg = lib.concatStringsSep ", " unwantedPresent;
in
assert lib.assertMsg (missing == [ ])
  "tests/sandbox-machined.nix: nix/home/sandbox/machined.nix did not wire expected xdg.configFile entr(y/ies): ${missingMsg}.";
assert lib.assertMsg (notAReference == [ ]) ''
  tests/sandbox-machined.nix: xdg.configFile entr(y/ies) not referencing pkgs.systemd verbatim: ${notAReferenceMsg}.
  machined.nix's design is a `.source` reference into pkgs.systemd, not hand-copied unit text — see its header comment for why that matters for the hardening directives these units carry.'';
assert lib.assertMsg (unwantedPresent == [ ]) ''
  tests/sandbox-machined.nix: found unit(s) that machined.nix's header says are deliberately NOT wired: ${unwantedPresentMsg}.
  The nspawn/vmspawn user templates and machines.target belong to a unit-managed container/VM workflow the sandbox launcher does not use (it invokes the binaries directly) — re-check the reasoning before adding them back.'';
pkgs.writeText "sandbox-machined-ok" ''
  units-present
  units-are-references
  templates-and-machines-target-unwired
''
