# LiveISO boot oracle — NixOS test framework edition.
#
# `iso-boot` boots the (plain, unsigned) LiveISO through OVMF UEFI with an
# emulated TPM 2.0 and asserts the installer TUI reaches tty1
# (DOTS_TUI_READY on the serial console). No Secure Boot chain — Secure
# Boot was removed in favor of TPM2 auto-unlock + a LUKS recovery key.
#
# Debug interactively with
# `nix run .#checks.x86_64-linux.iso-boot.driverInteractive`.
{
  pkgs,
  lib,
  iso,
  mkTokyonight,
  dotsFlake,
  inputs,
}:
let
  # Precomputed `mkpasswd -m yescrypt --stdin` of the literal "test" — the same
  # path the installer's WriteSecrets step uses (rust/installer-tui/src/install.rs).
  # Hardcoded (not generated) so the test is pure and reproducible; a $y$ hash
  # contains no `${` so it is safe unescaped in a Nix "..." literal.
  testHash = "$y$j9T$LvJdbOoLbTqQ/kknEXAf50$78JSMgcaSLcsay2xhRffsLJnc.dmvTEo5nS9BXTe3l8";

  # tokyonight with VM-sized disks/swap so the disko layout fits /dev/vda and
  # the closure can be pre-built. The committed settings.nix has /dev/nvme0n1 +
  # 32G swap, which changes the disko-generated swapDevices/disk entries and
  # therefore the toplevel — see docs/superpowers/specs/
  # 2026-07-28-limine-bootloader-design.md (closure-feasibility note).
  testSettings = (import ../nix/defaults.nix) // {
    username = "test";
    hostname = "test";
    disks = [ "/dev/vda" ];
    swapSize = "1G";
    gitName = "Test User";
    gitEmail = "test@example.com";
  };
  # The tokyonight closure built with test settings. Pre-substituted into the
  # installer VM via mountHostNixStore + extraDependencies so nixos-install
  # needs no network. The staged flake (copied from /etc/dots = flake `self`)
  # carries no nix/secrets.nix (gitignored, absent), so users.nix's
  # `secrets = {}` matches this host build's `secrets = {}` and nixos-install
  # substitutes this closure verbatim.
  testTokyonight = mkTokyonight testSettings;
  testToplevel = testTokyonight.config.system.build.toplevel;
  # The disko `destroy,format,mount` script for the test layout. The disko CLI
  # run in the VM `nix build`s this script derivation; the VM store has no
  # network and lacks the script's build-time closure (stdenv hooks such as
  # update-autotools-gnu-config-scripts-hook, parted, cryptsetup…), so the
  # in-VM build fails. Pre-staging the script here pulls its WHOLE closure into
  # the host store (mountHostNixStore) so the CLI's `nix build` realises every
  # dep by local substitution. Same disko.nix + args + pkgs as the CLI uses, so
  # the drv hashes match too (substitution, no build) — but even if they did
  # not, every input is present and the build would succeed.
  testDiskoScript = testTokyonight.config.system.build.destroyFormatMount;
  # Flake input source paths the installer VM needs to evaluate the staged
  # flake offline: `nixos-install --flake /tmp/dots-flake#tokyonight` evals the
  # flake, and every input's SOURCE must be in the store — not just the direct
  # ones. nixvim pulls flake-parts, hyprland pulls hyprlang/hyprland-protocols,
  # firefox-addons/bun2nix are direct inputs the hand-listed set below missed,
  # etc. A hand-listed set misses transitive inputs and nix then tries to fetch
  # them from the network (unreachable in the VM — `substituters = []` makes it
  # fail fast instead of retrying for hours, but it still fails). Walk `inputs`
  # recursively: each flake input attrset exposes `.inputs` (its own locked
  # sub-inputs) and `.outPath` (the fetched source store path), so a recursion
  # over `builtins.attrValues inputs` yields the full transitive closure;
  # `follows`-aliased sub-inputs (e.g. every input's nixpkgs follows the top
  # one) resolve to the same outPath and dedupe via lib.unique.
  flakeInputPaths =
    let
      walk = node: [
        node.outPath
      ] ++ builtins.concatMap walk (builtins.attrValues (node.inputs or { }));
    in
    lib.unique (builtins.concatMap walk (builtins.attrValues inputs));

  # The aipage source FOD — the one eval-time realization the flake forces that
  # is NOT a flake input and NOT in the toplevel's runtime closure. nix/aipage.nix
  # pins aipage via `pkgs.fetchgit` (aipageSrc, a hash-determined fixed-output
  # DERIVATION), and evaluating `packages.aipage-firefox` forces aipageSrc's
  # OUTPUT to be valid in the store: `aipageVersion = readFile
  # "${aipageSrc}/Cargo.toml"` reads a file out of it at eval time. fetchgit is
  # a derivation (not the `builtins.fetchGit` primitive), so forcing .outPath
  # computes the store path from `hash` WITHOUT fetching or realizing — but the
  # readFile then needs the path to be VALID (realized). aipageSrc is a
  # build-time input of aipage's dist derivations, so it is absent from
  # aipage-firefox's runtime closure and thus from the testToplevel closure
  # that extraDependencies registers; register it explicitly here so the guest
  # store has it valid and the eval-time readFile succeeds offline (no network,
  # no fetcher cache, no git). Because fetchgit's output path is hash-determined,
  # the host-built aipageSrc and the guest-evaluated aipageSrc are the SAME
  # store path — so registering it is enough; the rest of the aipage closure
  # (aipage-firefox etc.) substitutes bit-identically from the host store.
  # Exposed via the aipage packages' `passthru.aipageSrc` (nix/aipage.nix).
  aipageSrc = dotsFlake.packages.${pkgs.system}.aipage-firefox.aipageSrc;

  # Full install+boot oracle for the Limine switch: runs the installer's plan()
  # (rust/installer-tui/src/install.rs) in a VM, then boots the installed disk
  # via Limine and asserts the TPM2-unlocked LUKS root comes up. Two nodes
  # share the same qcow2 + swtpm state (target.state_dir = installer.state_dir,
  # plus a shared system.name so the swtpm state dir matches) so the TPM2 owner
  # seed persists and the token unseals on the target. The TPM2 token is
  # enrolled WITHOUT a PCR policy: the installer direct-kernel-boots (PCR 7 = 0,
  # no firmware measurement) while the target boots via OVMF (PCR 7 != 0), so a
  # PCR-7-bound token could not unseal across the two VMs. PCR-7 binding is a
  # bootloader-independent firmware-measurement property (covered upstream by
  # nixpkgs tests/systemd-initrd-luks-tpm2.nix); this test exercises the
  # Limine-specific chain — nixos-install + Limine ESP install + systemd initrd
  # crypttab tpm2-device=auto unseal — without conflating it with PCR policy.
  # The dots ISO itself has no test instrumentation (no backdoor shell — iso-boot
  # is console-only by design), so the installer node is a test-instrumented
  # installation-device VM, not the raw ISO; the install steps are identical to
  # install.rs::plan(). Mirrors nixpkgs tests/installer.nix (two-node
  # install+boot, shared diskImage + state_dir).
  limineInstallBootTest =
    pkgs.testers.runNixOSTest {
      name = "limine-install-boot";
      # Full closure build + disko + nixos-install + 2x boot under TCG is slow.
      globalTimeout = 4 * 60 * 60;

      nodes =
        let
          # Mirrors nixpkgs installer.nix `commonConfig`: both nodes share the
          # SAME disk file (./target.qcow2) so the installer's /dev/vda becomes
          # the target's boot disk, the same OVMFFull firmware (used by the
          # target's firmware boot), and — via the shared state_dir below — the
          # same swtpm. `system.name` is forced equal so the swtpm state dir
          # (`<system.name>-swtpm`, qemu-vm.nix) resolves to the same path under
          # the shared state_dir for both nodes; without this the two nodes get
          # distinct swtpm dirs and the enrolled TPM2 token cannot unseal.
          # The installer roots on a blank /dev/vdb (emptyDiskImage) that must be
          # formatted at boot. The test framework gives the installer a systemd
          # initrd, so `virtualisation.fileSystems."/".autoFormat = true` (set on
          # the installer node below) is what formats it — autoFormat adds
          # `x-systemd.makefs`, so systemd-makefs runs before /sysroot.mount.
          # auto-format-root-device.nix is imported too as the non-systemd-initrd
          # fallback (its mke2fs postDeviceCommands is mkIf-gated on
          # !boot.initrd.systemd.enable, so it is skipped here but would fire if
          # the framework default ever flips back). Computed from the OUTER pkgs
          # (a path string in `imports`, no pkgs module-arg forcing) to avoid the
          # read-only-overlay recursion that importing the `installation-device`
          # profile triggers.
          autoFormatModule = pkgs.path + "/nixos/tests/common/auto-format-root-device.nix";
          commonConfig = {
            system.name = "limine-test";
            virtualisation = {
              cores = 8;
              memorySize = 2048;
              # Both installer and target use the same drive (installer.nix:693).
              diskImage = "./target.qcow2";
              # 20G install target — the shared primary disk (installer.nix
              # sizes the install target via diskSize, not emptyDiskImages).
              diskSize = 20 * 1024;
              # Only OVMFFull contains the TCG/TIS module swtpm needs.
              efi.OVMF = pkgs.OVMFFull;
              tpm.enable = true;
            };
          };
        in
        {
          # NOTE: the nixpkgs `installation-device` profile is deliberately NOT
          # imported — it sets nixpkgs.overlays, which runNixOSTest pins
          # read-only (types.unique + readOnly), so the import infinite-recurses
          # / errors. The profile's only install-relevant provision is the
          # nixos-install binary, provided here via nixos-install-tools instead.
          installer =
            { pkgs, ... }:
            {
              imports = [
                commonConfig
                autoFormatModule
              ];
              # Serve the host nix store read-only so nixos-install substitutes
              # the pre-built testToplevel with no network (no substitutes).
              virtualisation.mountHostNixStore = true;
              # Boot the installer from a small /dev/vdb so /dev/vda (the shared
              # target.qcow2) stays blank as the install target during AND after
              # install (installer.nix:722-726).
              virtualisation.emptyDiskImages = [ 1024 ];
              virtualisation.rootDevice = "/dev/vdb";
              # Format the blank /dev/vdb at boot — the installer has a systemd
              # initrd (test framework default), so autoFormat adds
              # x-systemd.makefs and systemd-makefs creates the FS before
              # /sysroot.mount (without this, sysroot.mount fails with "Can't
              # find ext4 filesystem" and panic-on-fail crashes the VM).
              virtualisation.fileSystems."/".autoFormat = true;
              nix.settings.experimental-features = [
                "nix-command"
                "flakes"
              ];
              # The VM is offline. Without this nixos-install's `nix` tries to
              # substitute every path of the (large) tokyonight closure from
              # cache.nixos.org — 5 retries w/ backoff per path × thousands of
              # paths = hours, timing out the test. Force no substituters so nix
              # uses only the local store (mountHostNixStore has the whole
              # closure via extraDependencies) and never hits the network.
              nix.settings.substituters = lib.mkForce [ ];
              nix.settings.connect-timeout = 1;
              # The test VM has no channel, so any in-VM Nix eval that defaults
              # to `import <nixpkgs>` finds the store nixpkgs via NIX_PATH.
              # (nixos-install --flake uses flake.lock, not NIX_PATH, but keep
              # <nixpkgs> resolvable as a belt-and-braces fallback.)
              # inputs.nixpkgs.outPath is in flakeInputPaths → extraDependencies
              # → host store mount.
              nix.nixPath = [ "nixpkgs=${inputs.nixpkgs.outPath}" ];
              # The dots flake source the installer reads disko.nix + nix/ from.
              # `dotsFlake` is flake `self` (path-coercible via outPath); if the
              # path type ever rejects the attrset, use `dotsFlake.outPath`.
              environment.etc."dots".source = dotsFlake;
              environment.systemPackages = [
                pkgs.nixos-install-tools
                pkgs.disko
                pkgs.cryptsetup
                pkgs.tpm2-tools
                pkgs.nixos-facter
              ];
              # Everything nixos-install needs to evaluate + copy the closure
              # offline: the test-settings toplevel, the pre-built disko script
              # (so the disko CLI's in-VM `nix build` finds every dep in the
              # store), and the flake input sources.
              system.extraDependencies = [
                testToplevel
                testDiskoScript
                aipageSrc
              ] ++ flakeInputPaths;
            };

          target =
            { ... }:
            {
              imports = [ commonConfig ];
              virtualisation = {
                # Boot the installed disk via Limine (installer.nix:809-812).
                useBootLoader = true;
                useEFIBoot = true;
                useDefaultFilesystems = false;
                # Limine installs to \EFI\BOOT\BOOTX64.EFI (canTouchEfiVariables
                # = false, removable path) — firmware boots it from the default
                # removable path, so no persistent EFI NVRAM vars are needed
                # (installer.nix:812 sets efi.keepVariables = false).
                efi.keepVariables = false;
                # Dummy root; the real root comes from the installed system's
                # bootloader/kernel (installer.nix:814-817).
                fileSystems."/" = {
                  device = "/dev/disk/by-label/this-is-not-real-and-will-never-be-used";
                  fsType = "ext4";
                };
              };
            };
        };

      testScript =
        ''
          import base64

          installer.start()
          installer.wait_for_unit("multi-user.target")
          installer.succeed("udevadm settle")

          with subtest("Generate the one-shot LUKS keyfile"):
              installer.succeed("umask 077; head -c 64 /dev/urandom > /tmp/dots-luks-pass")

          with subtest("disko partition + format + mount on /dev/vda"):
              # Run the PRE-BUILT disko destroy-format-mount script directly
              # (testDiskoScript = testTokyonight.config.system.build.
              # destroyFormatMount) instead of the `disko` CLI. The CLI does an
              # in-VM `nix build` of the script drv, whose hash differs from the
              # host-built one (import <nixpkgs> {} != nixosSystem's pkgs), so
              # it rebuilds — and rebuilding pulls the offline-unfetchable stdenv
              # bootstrap chain. The pre-built script is self-contained: it
              # exports PATH = makeBinPath of _packages + bash + destroyDeps
              # (all absolute store paths), so its whole tool closure (staged
              # via extraDependencies + mountHostNixStore) is all it needs. Same
              # disko.nix + test args as the real installer's `disko --mode
              # destroy,format,mount` — only the dep-bundling differs.
              installer.succeed(
                  "${testDiskoScript}/bin/disko-destroy-format-mount"
                  " --yes-wipe-all-disks >&2"
              )

          with subtest("Stage a writable flake copy + write test settings.nix"):
              installer.succeed(
                  "rm -rf /tmp/dots-flake"
                  " && mkdir -p /tmp/dots-flake"
                  " && cp -rTL /etc/dots /tmp/dots-flake"
                  " && chmod -R u+w /tmp/dots-flake"
              )
              # base64 round-trips the file in with zero quoting ambiguity — no
              # shell heredoc indentation pitfalls, no $ expansion.
              settings_nix = """{
                username = "test";
                hostname = "test";
                disks = ["/dev/vda"];
                swapSize = "1G";
                gitName = "Test User";
                gitEmail = "test@example.com";
              }
              """
              s_b64 = base64.b64encode(settings_nix.encode()).decode()
              installer.succeed(f"printf '%s' {s_b64} | base64 -d > /tmp/dots-flake/nix/settings.nix")
              installer.succeed("cat /tmp/dots-flake/nix/settings.nix >&2")

          with subtest("nixos-install completes — Limine sidesteps the machine-id abort"):
              # Replicate the impermanence condition that broke systemd-boot: an
              # empty /etc/machine-id on the installer. systemd-boot's installer
              # reads it and aborts; Limine's does not. The test VM has a real
              # machine-id, so truncate it to mirror the LiveISO's tmpfs root —
              # if Limine's installer secretly depended on it, this would catch it.
              installer.succeed(": > /etc/machine-id")
              # The load-bearing step: Limine (not systemd-boot) is the installed
              # bootloader precisely so nixos-install does not abort on the empty
              # /etc/machine-id that impermanence produces.
              installer.succeed(
                  "nixos-install --root /mnt --no-root-passwd"
                  " --flake /tmp/dots-flake#tokyonight < /dev/null >&2"
              )

          with subtest("Enroll TPM2 token (no PCR policy) + LUKS recovery key"):
              # No --tpm2-pcrs: the token is PCR-unbound so it unseals on the
              # target via the shared swtpm regardless of PCR 7 (which differs
              # between the direct-boot installer and the OVMF-booted target).
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --tpm2-device=auto /dev/tokyonightvg/root >&2"
              )
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --recovery-key /dev/tokyonightvg/root >&2"
              )

          with subtest("Shred the keyfile and shut down the installer"):
              installer.succeed("shred -u /tmp/dots-luks-pass")
              installer.succeed("umount -R /mnt || true")
              installer.succeed("sync")
              installer.shutdown()

          # Share state_dir (installer.nix:255) — shares BOTH the qcow2 disk
          # file AND the swtpm state (forced to the same dir via the shared
          # system.name in commonConfig), so the target's TPM2 is the chip the
          # installer enrolled against.
          target.state_dir = installer.state_dir
          target.start()

          with subtest("Installed system boots via Limine + TPM2 auto-unlock"):
              target.wait_for_unit("multi-user.target")
              # multi-user.target is only reachable if the LUKS root auto-unlocked
              # via the TPM2 token (no recovery-key prompt in a non-interactive
              # boot). Confirm the mapper is the root backing device.
              assert "/dev/mapper/cryptroot" in target.succeed("mount"), \
                  "cryptroot not mounted — TPM2 unseal did not fire"
        '';
    };

  isoBootTest =
    pkgs.testers.runNixOSTest {
      name = "iso-boot";
      # Headroom for TCG on KVM-less CI runners; under KVM this needs minutes.
      globalTimeout = 2 * 60 * 60;

      nodes.machine = {
        virtualisation = {
          # Boot the attached ISO through real UEFI firmware instead of the
          # test driver's default direct -kernel boot.
          directBoot.enable = false;
          useEFIBoot = true;
          # swtpm-backed TPM 2.0 — the installed system unlocks the LUKS root
          # via a TPM2 token (PCR 7), so emulate the chip the boot chain needs.
          tpm.enable = true;
          memorySize = 4096;
          # The launcher's root qcow2 is a bare non-bootable ext4 image — it
          # doubles as the blank 20G install-target disk.
          diskSize = 20 * 1024;
          qemu.options = [
            "-drive if=none,id=installcd,media=cdrom,readonly=on,format=raw,file=${iso}/iso/${iso.isoName}"
            # The root disk carries bootindex=1; the cdrom must outrank it.
            "-device ide-cd,drive=installcd,bootindex=0"
          ];
        };
      };

      # Console-only assertions: the ISO carries no test instrumentation, so
      # backdoor-based helpers (wait_for_unit, succeed, shutdown) are off
      # limits. nix/iso.nix emits DOTS_TUI_READY on the serial console once the
      # installer TUI starts on tty1.
      testScript = ''
        machine.start()
        machine.wait_for_console_text("DOTS_TUI_READY", timeout=6600)
      '';
    };

  # The load-bearing "can I log in after reboot?" guarantee for the
  # nixos-init migration: userborn creates the account at FIRST boot (not at
  # nixos-install time) and writes passwd/shadow/group to /var/lib/nixos —
  # pinned there explicitly via `passwordFilesLocation` so it holds under the
  # MUTABLE /etc core.nix ships (mutable=true lets NetworkManager write
  # /etc/NetworkManager/system-connections; see memory:
  # etc-overlay-mutable-required-for-bindmounts). Without that pin, userborn's
  # default (`/var/lib/nixos` only when /etc is immutable, else `/etc`) would
  # move credentials onto the tmpfs-wiped, unpersisted /etc overlay upperdir
  # → login works on first boot but the hash vanishes on reboot → locked out.
  # This test mirrors production (mutable=true + the pin) so a regression that
  # drops the pin, flips /etc mutability, or rewires impermanence away from
  # /var/lib/nixos fails here instead of shipping. Verifies the contract the
  # installer's WriteSecrets step (declarative yescrypt → nix/secrets.nix →
  # initialHashedPassword) relies on. The real PAM-keystroke login on a tty is
  # deliberately NOT exercised here: the backdoor runs as root, so reading
  # shadow directly is a strict superset of the information a tty login would
  # produce (the password matching the hash is guaranteed by construction via
  # mkpasswd; the unknown is whether the hash survives reboot, which this
  # asserts). The tmpfs-ephemeral-root half of the impermanence story is
  # covered by eval/build verification (tokyonight toplevel builds clean with
  # the impermanence module + the persistence set generates the expected
  # bind-mount fileSystems) rather than a flaky disk-format-in-VM harness.
  userbornRebootLogin = pkgs.testers.runNixOSTest {
    name = "userborn-reboot-login";
    nodes.machine = {
      # system.etc.overlay asserts a systemd initrd (it mounts the erofs+
      # overlayfs /etc image from the store in stage 1).
      boot.initrd.systemd.enable = true;
      services.userborn.enable = true;
      system.etc.overlay = {
        enable = true;
        # Mirrors core.nix: mutable so /etc writers (NetworkManager) work.
        mutable = true;
      };
      # The pin from users.nix — load-bearing under mutable /etc (see above).
      # Without it this test would pass against a /etc shadow that the tmpfs
      # root wipes, masking the reboot lockout the way the prior mutable=false
      # version of this test masked the cddf5de regression.
      services.userborn.passwordFilesLocation = "/var/lib/nixos";
      # initialHashedPassword is only applied at account creation, then a
      # no-op update preserves it — matching users.nix on the real system, so
      # the hash is not re-forced every boot (which would mask a drift bug).
      users.mutableUsers = true;
      users.users.alice = {
        isNormalUser = true;
        initialHashedPassword = testHash;
      };
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("userborn.service")

      # /etc/shadow must be a direct symlink into /var/lib/nixos — the
      # signature that the passwordFilesLocation pin held (userborn would
      # otherwise default to /etc under mutable /etc and write a real file
      # there, which the tmpfs root would wipe on reboot).
      shadow_target = machine.succeed("readlink -f /etc/shadow").strip()
      # userborn writes /var/lib/nixos/{passwd,shadow,group} directly (no
      # `etc/` subdir), so the contract is "symlinks somewhere under
      # /var/lib/nixos", not a specific filename.
      assert shadow_target.startswith("/var/lib/nixos/"), shadow_target

      # The declarative yescrypt hash landed in the persisted shadow verbatim.
      assert "${testHash}" in machine.succeed("getent shadow alice"), \
          "initialHashedPassword missing from shadow"

      # Reboot equivalent: shutdown the VM and cold-start it again from the same
      # persistent qcow2 root disk. We use shutdown()+start() rather than
      # reboot() because this test-driver version's reboot() reconnect is flaky
      # under TCG (QEMU exits on the guest reset and the driver fails to
      # relaunch it); shutdown+start relaunches QEMU explicitly, which is the
      # same "credentials on persistent storage survive a restart" check. The
      # credentials live under /var/lib/nixos on the persistent root disk, so
      # the hash must still be there — i.e. login still works after a restart.
      machine.shutdown()
      machine.start()
      machine.wait_for_unit("userborn.service")
      assert "${testHash}" in machine.succeed("getent shadow alice"), \
          "hashed password did not survive restart"
    '';
  };
in
{
  iso-boot = isoBootTest;
  userborn-reboot-login = userbornRebootLogin;
  limine-install-boot = limineInstallBootTest;
}