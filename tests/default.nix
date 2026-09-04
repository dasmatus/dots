# LiveISO boot oracle — NixOS test framework edition.
#
# `iso-boot` boots the (plain, unsigned) LiveISO through OVMF UEFI with an
# emulated TPM 2.0 and asserts the cage kiosk's Quickshell session reaches
# tty1 (DOTS_UI_READY on the serial console). No Secure Boot chain — Secure
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
  # session-units — eval-only, costs nothing (no VM, no build): a standalone
  # home-manager evaluation checked with five `assert`s. Everything else in
  # this file is a heavy `pkgs.testers.runNixOSTest`; this one is here so
  # that contrast is visible at the call site rather than buried next to
  # `iso-boot`. See tests/session-units.nix for what it guards.
  sessionUnitsTest = import ./session-units.nix { inherit pkgs lib inputs; };

  # proton-calendar — eval-only for the same reason as sessionUnitsTest, and
  # guarding the one seam nothing else covers: nix/home/proton/proton.nix runs
  # Betterbird while nix/home/proton/proton-calendar.nix delivers the calendar as
  # prefs in the mail profile, which only works while home-manager keeps that
  # profile at ~/.thunderbird. See tests/proton-calendar.nix.
  protonCalendarTest = import ./proton-calendar.nix { inherit pkgs lib inputs; };

  # limine-install-home — a lightweight runNixOSTest (no disko, no
  # nixos-install, no facter.json wall) pinning nix/modules/system/limine-install.nix's
  # hazard-1 HOME-provisioning fix under three HOME conditions. See
  # tests/limine-home.nix for what it guards and why it needs a VM rather
  # than an eval-only check.
  limineHomeTest = import ./limine-home.nix { inherit pkgs lib; };

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
  testSettings = (import ../nix/system/defaults.nix) // {
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
  # limine-install.nix's ensureOwnedHome fix exposes this standalone probe
  # (nix/modules/system/limine-install.nix, "exposed only for tests/limine-home.nix")
  # so its $HOME-recovery branch can be inspected without invoking the real
  # upstream Limine installer. limineInstallBootTest below runs it right after
  # nixos-install, through the same nixos-enter chroot nixos-install itself
  # uses for the bootloader step, to record which branch fired on the real
  # install path instead of only the synthetic conditions limineHomeTest sets
  # up directly.
  testHomeProbe = testTokyonight.config.system.build.limineEnsureOwnedHomeProbe;
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
      walk =
        node:
        [
          node.outPath
        ]
        ++ builtins.concatMap walk (builtins.attrValues (node.inputs or { }));
    in
    lib.unique (builtins.concatMap walk (builtins.attrValues inputs));

  # The aipage source FOD — the one eval-time realization the flake forces that
  # is NOT a flake input and NOT in the toplevel's runtime closure. nix/packages/aipage.nix
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
  # Exposed via the aipage packages' `passthru.aipageSrc` (nix/packages/aipage.nix).
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
  limineInstallBootTest = pkgs.testers.runNixOSTest {
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
        # / errors. `../../profiles/base.nix` (which installation-device.nix's
        # own parent, installation-cd-base.nix, also imports) carries none of
        # that: it is what actually puts parted/gptfdisk/cryptsetup on the
        # real ISO and, via `boot.supportedFilesystems`, is what makes NixOS's
        # own filesystem-task modules (tasks/filesystems/btrfs.nix, lvm.nix's
        # services.lvm.enable default, …) pull in btrfs-progs/lvm2/dosfstools/
        # e2fsprogs — the same generic installer toolkit `nix/system/iso.nix:35`
        # gets from `installation-cd-minimal.nix`. Importing it here is what
        # lets the disko CLI below resolve its own independently-evaluated
        # derivation (a different pkgs instantiation than this node's, see
        # the disko step) against packages this node already has *valid*,
        # rather than needing to build or fetch them. `boot.swraid.enable`
        # is the one piece installation-device.nix would otherwise add
        # (mdadm, for disko's RAID-capable `_pkgs` default set) — set
        # directly since the module that normally sets it is off-limits.
        installer =
          { pkgs, modulesPath, ... }:
          {
            imports = [
              commonConfig
              autoFormatModule
              "${modulesPath}/profiles/base.nix"
            ];
            boot.swraid.enable = true;
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
            # offline: the test-settings toplevel, the flake input sources,
            # and the $HOME probe (system.build.limineEnsureOwnedHomeProbe)
            # the testScript runs after nixos-install to observe hazard 1
            # (nix/modules/system/limine-install.nix) on the real install path.
            # profiles/base.nix above gives this node the same *runtime*
            # PATH packages disko's script needs (parted, lvm2, …), but not
            # the *build-time* tool disko's cryptsetup-wrapping step needs to
            # realise that script in the first place: pkgs.makeBinaryWrapper
            # (nix/system/iso.nix stages the same derivation, with the full
            # reasoning — its own build environment is the ordinary
            # cc-having stdenv, and nothing else here pulls it in, so its
            # absence sends disko's in-VM `nix build` all the way through a
            # from-source gcc/binutils bootstrap that has no network to
            # fetch through).
            system.extraDependencies = [
              testToplevel
              testHomeProbe
              aipageSrc
              pkgs.makeBinaryWrapper
            ]
            ++ flakeInputPaths;
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

    testScript = ''
      import base64

      installer.start()
      installer.wait_for_unit("multi-user.target")
      installer.succeed("udevadm settle")

      with subtest("Generate the one-shot LUKS keyfile"):
          installer.succeed("umask 077; head -c 64 /dev/urandom > /tmp/dots-luks-pass")

      with subtest("disko partition + format + mount on /dev/vda (the disko CLI, same as install.rs::plan())"):
          # The literal command install.rs's plan() runs — `disko --mode
          # destroy,format,mount --yes-wipe-all-disks --arg disks [...]
          # --argstr swapSize <swap> {flake_src}/nix/system/disko.nix`
          # (rust/installer-tui/src/install.rs) — against /etc/dots, the
          # read-only flake mount, exactly as a real install does; nixos-install
          # stages its own writable copy separately, below. disks/swapSize
          # mirror testSettings above.
          #
          # The CLI evaluates its own script derivation (`import <nixpkgs> {}`
          # via disko's pinned NIX_PATH) rather than reading
          # config.system.build.destroyFormatMount (built through this node's
          # own, module-system-computed pkgs) — a different derivation whose
          # `nix build` this node must resolve on its own. profiles/base.nix
          # above (imported the way nix/system/iso.nix:35 pulls in
          # installation-cd-minimal.nix, minus the overlay it can't take
          # here) gives this node its own, properly built copy of every
          # package that build needs — parted/gptfdisk/cryptsetup directly,
          # lvm2/btrfs-progs/dosfstools/e2fsprogs/mdadm via
          # boot.supportedFilesystems + boot.swraid.enable — so the CLI's
          # `nix build` finds them already valid and never touches the
          # network, the same way the real ISO's own store already carries
          # them. The one thing profiles/base.nix does not cover is
          # pkgs.makeBinaryWrapper, a *build-time* tool disko's
          # cryptsetup-wrapping step needs rather than a runtime PATH
          # package — staged separately in this node's
          # system.extraDependencies above (see that comment).
          installer.succeed(
              "disko --mode destroy,format,mount --yes-wipe-all-disks"
              " --arg disks '[ \"/dev/vda\" ]' --argstr swapSize 1G"
              " /etc/dots/nix/system/disko.nix >&2"
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
          installer.succeed(f"printf '%s' {s_b64} | base64 -d > /tmp/dots-flake/nix/data/settings.nix")
          installer.succeed("cat /tmp/dots-flake/nix/data/settings.nix >&2")

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

      with subtest("Probe the $HOME limine-install.nix's bootloader step saw"):
          # nixos-install's own bootloader step shells out to
          # `nixos-enter --root "$mountPoint" -c '... switch-to-configuration
          # boot'` (nixpkgs' nixos-install.sh) — a plain `chroot` with no HOME
          # handling of its own, so whatever ensureOwnedHome
          # (nix/modules/system/limine-install.nix) saw is whatever that same
          # invocation shape inherits. Run the exposed probe (testHomeProbe =
          # system.build.limineEnsureOwnedHomeProbe, "exposed only for
          # tests/limine-home.nix") through an identical nixos-enter chroot,
          # right after nixos-install returns, to observe the real install
          # path's outcome without touching production code or the real
          # nixos-install run above. Nothing between the two nixos-enter
          # invocations touches /mnt/root, so its existence/ownership — the
          # ensureOwnedHome condition — should match what the real run saw.
          home_seen = installer.succeed(
              "nixos-enter --root /mnt -c ${testHomeProbe} 2>&1"
          ).strip()
          print(f"limine-install.nix ensureOwnedHome saw HOME={home_seen!r}")

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

  isoBootTest = pkgs.testers.runNixOSTest {
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
    # limits. installer.qml (Quickshell) emits DOTS_UI_READY on the serial
    # console from Component.onCompleted, once cage has actually mapped its
    # window on tty1 — nix/system/iso.nix's unit no longer emits any marker itself.
    testScript = ''
      machine.start()
      machine.wait_for_console_text("DOTS_UI_READY", timeout=6600)
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

  # Proves the agentmem cluster (nix/modules/services/agentmem.nix) is reachable over
  # its unix socket by peer auth, survives an impermanence-style reboot, and
  # that the backup dump it produces actually restores — against a real
  # import of nix/modules/system/impermanence.nix, not a hand-rolled bind mount, so
  # a change to the persistence machinery breaks this test first. Role/db
  # "test" stands in for the installer-collected username; agentmem.nix's
  # own dots.ai.claude gate is not exercised here (that is an eval-level
  # concern, checked by flake/checks.nix), only the
  # services.postgresql/postgresqlBackup shape it produces once gated on.
  agentmemPostgresTest = pkgs.testers.runNixOSTest {
    name = "agentmem-postgres";

    nodes.machine =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.impermanence.nixosModules.impermanence
          ../nix/modules/system/impermanence.nix
        ];
        # impermanence.nix reads config.dots.paths.stateDir for one of its
        # (unrelated, here-irrelevant) persisted directories — stub it
        # rather than pull in the whole nix/modules/dots.nix option tree.
        options.dots.paths.stateDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/dots";
        };

        config = {
          # A real disk-backed /persist so the bind-mounts below survive the
          # shutdown()/start() cycle — standing in for disko's @persist
          # subvolume (neededForBoot, forced by impermanence.nix, needs a
          # systemd initrd to mount + format this early).
          boot.initrd.systemd.enable = true;
          virtualisation.emptyDiskImages = [ 512 ];
          # virtualisation.fileSystems (not the plain fileSystems attribute)
          # is what actually reaches the built VM — qemu-vm.nix overrides
          # fileSystems wholesale with this mirror, so neededForBoot must be
          # set here too: impermanence.nix's own mkForce on the plain
          # fileSystems."/persist" never reaches the overridden value.
          virtualisation.fileSystems."/persist" = {
            device = "/dev/vdb";
            fsType = "ext4";
            autoFormat = true;
            neededForBoot = true;
          };

          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_18;
            ensureDatabases = [ "test" ];
            ensureUsers = [
              {
                name = "test";
                ensureDBOwnership = true;
              }
            ];
            enableTCPIP = false;
          };
          services.postgresqlBackup = {
            enable = true;
            location = "/var/lib/postgresql/backup";
            startAt = "daily";
          };
          users.users.test.isNormalUser = true;
        };
      };

    testScript = ''
      machine.start()
      # postgresql.service only starts the server -- ensureUsers/
      # ensureDatabases run in the separate postgresql-setup.service oneshot
      # (requires+after postgresql.service), so the "test" role and database
      # do not exist yet the instant postgresql.service is merely active.
      machine.wait_for_unit("postgresql-setup.service")

      with subtest("socket reachability and peer auth"):
          machine.succeed("sudo -u test psql -h /run/postgresql -d test -c 'select 1;'")

      with subtest("a written row survives a reboot"):
          machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -c "
              "'create table t (n int); insert into t values (1);'"
          )
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("postgresql-setup.service")
          out = machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -tAc 'select n from t;'"
          ).strip()
          assert out == "1", f"row lost across reboot: {out!r}"

      with subtest("the backup dump lands under the persisted parent"):
          machine.succeed("systemctl start postgresqlBackup.service")
          machine.succeed("test -s /var/lib/postgresql/backup/all.sql.gz")

      with subtest("the backup dump actually restores"):
          # Known rows, distinct from the "t" table above so a leftover row
          # in "t" cannot be mistaken for a successful restore.
          machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -c "
              "'create table restore_check (id int primary key, value int); "
              "insert into restore_check values (1, 111), (2, 222);'"
          )
          # pg_dumpall (backupAll, the default with no databases listed) dumps
          # the whole cluster as it stands right now, so the dump must be
          # forced again after the insert above rather than reusing the one
          # from the previous subtest.
          machine.succeed("systemctl start postgresqlBackup.service")
          machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -c "
              "'truncate restore_check;'"
          )
          emptied = machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -tAc "
              "'select count(*) from restore_check;'"
          ).strip()
          assert emptied == "0", f"truncate did not clear the table: {emptied!r}"
          # Restore as the postgres superuser, same as pg_dumpall's own
          # convention: the dump's CREATE ROLE/CREATE DATABASE/CREATE TABLE
          # statements error out because those objects already exist (no
          # --clean, matching pgdumpAllOptions' default of ""), and psql
          # without -v ON_ERROR_STOP=1 keeps going past each one — the COPY
          # statements that follow still find their tables and refill them.
          machine.succeed(
              "${pkgs.gzip}/bin/zcat /var/lib/postgresql/backup/all.sql.gz"
              " | sudo -u postgres psql -h /run/postgresql -d postgres -f - >&2"
          )
          restored = machine.succeed(
              "sudo -u test psql -h /run/postgresql -d test -tAc "
              "'select id, value from restore_check order by id;'"
          ).strip()
          assert restored == "1|111\n2|222", \
              f"restore did not bring back the known rows: {restored!r}"
    '';
  };
in
{
  # Eval-only — no VM, no build. See the comment on sessionUnitsTest above.
  session-units = sessionUnitsTest;
  proton-calendar = protonCalendarTest;
  iso-boot = isoBootTest;
  userborn-reboot-login = userbornRebootLogin;
  limine-install-home = limineHomeTest;
  limine-install-boot = limineInstallBootTest;
  agentmem-postgres = agentmemPostgresTest;
}
