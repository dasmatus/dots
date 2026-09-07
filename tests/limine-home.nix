# Regression guard for nix/modules/system/limine-install.nix's hazard-1 fix ("fix:
# run the real mktemp when limine-install needs a home"): a NixOS VM test,
# not an eval-only check, because the property under test is runtime bash
# behaviour — does mktemp actually get invoked, does $HOME actually get
# reassigned or left alone — under three HOME conditions, one of which (an
# existing directory the running user does not own) only a real multi-user
# system can produce honestly. A Nix build-sandbox derivation cannot: the
# sandbox's own UID-namespace remapping makes "chown to a uid we don't
# control" either impossible or an implementation-detail-dependent trick,
# neither of which is something to pin a regression test on.
#
# Deliberately does NOT go through flake/nixos.nix's mkTokyonight /
# nixosConfigurations.tokyonight: both pull in nix/system/hosts.nix and the
# whole system closure with it, which is far more evaluation than a probe over
# one bootloader script needs. (Historically it was a hard wall, not just a
# cost: nix/data/facter.json was a symlink into /var/lib/dots that a bare
# checkout could not read. That is fixed — both files are real in-tree stubs
# now — so this is a scoping choice today.) This test imports
# nix/modules/system/limine-install.nix directly into a minimal machine, so it
# evaluates and builds with no machine-specific state at all.
#
# nix/modules/system/limine-install.nix factors the hazard-1 conditional out of
# installBootLoader's text into `ensureOwnedHome`, and exposes a standalone
# runner over it as `config.system.build.limineEnsureOwnedHomeProbe` — the
# exact bash this test runs, not a hand-copied twin that could drift from
# what ships. The probe runs the conditional, then prints the resulting
# $HOME so a test can assert on stdout without pulling in hazard 2 or the
# real upstream Limine installer.
{ pkgs, lib, ... }:
pkgs.testers.runNixOSTest {
  name = "limine-install-home";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ ../nix/modules/system/limine-install.nix ];
      boot.loader.limine.enable = true;

      # A real second account — the "installer runs as one user against a
      # home belonging to another" case from the bug report needs a genuine
      # ownership mismatch, not a simulated one.
      users.users.owner = {
        isNormalUser = true;
        uid = 3000;
      };

      environment.etc."limine-ensure-owned-home-probe".source =
        config.system.build.limineEnsureOwnedHomeProbe;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    probe = "/etc/limine-ensure-owned-home-probe"

    with subtest("HOME unset -- provisions a temp home the caller owns"):
        out = machine.succeed(f"env -u HOME {probe}").strip()
        assert out.startswith("/tmp/"), \
            f"expected an owned mktemp -d path under /tmp, got {out!r}"
        owner = machine.succeed(f"stat -c %U {out}").strip()
        assert owner == "root", \
            f"provisioned home {out!r} is owned by {owner!r}, not the caller (root)"

    with subtest("HOME owned by a different user -- provisions a temp home the caller owns"):
        # nixos-install's bootloader step runs as root, same as machine.succeed
        # here — root's stat() bypasses the 0700 permission bits on owner's
        # home, so this is the genuine ownership-metadata mismatch the fix
        # guards against, not a traversal-permission accident an unprivileged
        # caller would hit instead.
        machine.succeed("install -d -o owner -g users -m 0700 /home/owner/theirs")
        out = machine.succeed(f"env HOME=/home/owner/theirs {probe}").strip()
        assert out != "/home/owner/theirs", \
            "the probe left HOME pointed at a directory the caller does not own"
        assert out.startswith("/tmp/"), \
            f"expected an owned mktemp -d path under /tmp, got {out!r}"
        owner = machine.succeed(f"stat -c %U {out}").strip()
        assert owner == "root", \
            f"provisioned home {out!r} is owned by {owner!r}, not the caller (root)"

    with subtest("HOME owned by the caller -- left untouched, no mktemp"):
        out = machine.succeed(f"runuser -u owner -- env HOME=/home/owner {probe}").strip()
        assert out == "/home/owner", \
            f"the probe replaced an already-owned HOME: got {out!r}"
  '';
}
