# Phase 0 boot oracle — the gate every later hardening phase (XWayland
# removal, kernel lockdown, the CFI/ThinLTO kernel, AppArmor enforcement)
# has to keep green. It exists to close a real coverage gap:
# tests/session-units.nix is eval-only (a standalone home-manager evaluation,
# no VM, no activation), and the `DOTS_UI_READY` marker in tests/default.nix
# belongs to the LiveISO installer's Quickshell running under `cage` on tty1
# — neither one ever boots the INSTALLED system's Hyprland session. That gap
# is exactly what incident `9b069e8` fell through: flipping the AppArmor
# store catch-all to enforce killed every setuid binary under
# `/run/wrappers/bin` and left greetd restart-looping into start-limit-hit,
# caught by hand rather than by a test. See
# docs/superpowers/specs/2026-09-08-hardening-design.md ("Phase 0") for the
# project this guards.
#
# ── Route: tokyonightModules, not extendModules over the real
#    nixosConfigurations.tokyonight ────────────────────────────────────────
#
# flake/checks.nix's extendModules variants (facter-nvidia-eval,
# fido-2fa-strict-eval) are eval-only — they never force a VM to actually
# boot. Doing the same here, i.e. `dotsFlake.nixosConfigurations.tokyonight
# .extendModules { modules = [ testOverrides ]; }` and handing the result to
# `pkgs.testers.runNixOSTest`, was tried first and rejected: the real
# tokyonight closure imports disko.nix (LVM + TPM2-LUKS2 targeting a real
# `/dev/…` disk) and impermanence.nix (a tmpfs `/`, bind-mounted from a
# disko-managed `/persist` btrfs subvol). The test framework's
# `virtualisation.useDefaultFilesystems` (on by default) forces `fileSystems`
# itself via `mkVMOverride`, but it knows nothing about
# `boot.initrd.luks.devices` or the extra `/persist`/`/nix` filesystem
# entries impermanence.nix marks `neededForBoot` — both would still point at
# devices that do not exist in a plain test VM, and the initrd would hang
# waiting for them. Overriding every option disko.nix and impermanence.nix
# touch (fileSystems, swapDevices, boot.initrd.luks.devices,
# environment.persistence, boot.zswap — zswap asserts at least one physical
# swap device) is exactly as much bespoke bookkeeping as building the module
# list by hand, with the added risk of an eval-order surprise from
# `extendModules` fighting the base module's own `mkForce`s.
#
# So: this file builds `nodes.machine` from `tokyonightModules` —
# `flake/nixos.nix`'s own export of the disk-independent half of
# tokyonight's module list, the same list `mkTokyonight` concatenates its
# disk/boot-chain modules onto. It is NOT a hand-copied duplicate: a module
# added to or removed from `tokyonightModules` changes what this gate covers
# the moment `flake/nixos.nix` changes, with no second edit here to forget.
# Only the disk-and-boot-chain half stays out —
# `disko.nixosModules.disko`, `impermanence.nixosModules.impermanence`,
# `nix/system/disko.nix`, `nix/modules/system/impermanence.nix`,
# `nix/modules/system/limine-install.nix` (`flake/nixos.nix`'s
# `tokyonightDiskModules`) — none of which the graphical session depends on;
# the test framework boots this VM by direct kernel/initrd invocation
# regardless of `boot.loader.*`. `tokyonightModules` DOES include
# `nix/modules/system/boot.nix`: it is the only consumer of
# `settings.bootKernelParams` (merged with `hardening.nix`'s own kargs at
# the `boot.kernelParams` option), and this project's own design doc
# rulings R1/R2 plan to move `module.sig_enforce=1` and
# `lockdown=confidentiality` into that same settings surface — a gate blind
# to the kargs the project is about to add would go green while the real
# machine loses its session. `boot.zswap.enable` is forced off in
# `testOverrides` below (no disko means no swap device for it to sit in
# front of); nothing else in boot.nix needs a real disk to build or boot
# under the test framework's direct-kernel-boot path.
#
# This follows the route the task dispatch sanctioned as a fallback if the
# full-closure `extendModules` route proved impractical: build the test
# machine from tokyonight's module list with the disk/impermanence modules
# replaced by test-appropriate ones, provided the desktop stack (desktop.nix,
# the home-manager session, quickshell) stays real. It does — every module
# in `tokyonightModules` is the production one, unmodified, including both
# AppArmor modules the 9b069e8 incident is about.
#
# ── Known gap: the real greeter is not exercised ────────────────────────────
#
# `testOverrides` below drives the session through greetd's
# `initial_session`, which bypasses regreet's `default_session` entirely —
# confirmed against this test's own runs, whose console log shows a PAM
# session opened and closed for the "test" user around the `initial_session`
# command, the same mechanism greetd uses for any configured session. An
# AppArmor enforce flip that breaks regreet SPECIFICALLY (rather than
# whatever `initial_session` execs) is not caught here, and that path is
# arguably closer to the actual 9b069e8 mechanism than autologin is.
# Driving regreet through interactive PAM in a VM was ruled out of
# proportion for this gate — Task 5's owner (who flips AppArmor profiles to
# enforce) should read this as a known blind spot, not as coverage that
# already exists.
#
# ── Test-only settings and overrides ────────────────────────────────────────
#
# `settings`: the same shape tests/default.nix's `testSettings` uses
# (username/hostname "test", disks/swapSize dummied out — inert here since
# no disko module reads them), PLUS `aiClaude`/`aiCodex`/`aiOllama` forced
# off. That last trio is the point of the test talking, not hardening
# behaviour: a `nix build` of a NixOS test runs inside Nix's own build
# sandbox, which has no network access by design (reproducibility), and
# ollama's `loadModels` would otherwise try to pull gigabytes from a
# registry that is unreachable there. The desktop stack itself needs none of
# the three to boot.
#
# `testOverrides` additionally neutralises the two home-manager units that
# reach the real internet on every login on real hardware and would
# otherwise sit in `auto-restart` for the length of this test, defeating
# assertion 5 for a reason that has nothing to do with the graphical
# session:
#   - `dots-clone` (nix/home/base/dots-repo.nix) — `git clone
#     https://codeberg.org/dasmatus/dots`, `WantedBy = [ "default.target" ]`,
#     `Restart = "on-failure"`.
#   - nix-flatpak's `flatpak-managed-install` (nix/home/base/flatpaks.nix,
#     `services.flatpak.enable = true`) — installs every Flathub ref in that
#     file, also `WantedBy = [ "default.target" ]` with its own retry.
# Both fail fast and harmlessly on real hardware's first offline boot too;
# disabling them here only removes noise this test was never meant to
# judge. Every other `WantedBy = default.target/graphical-session.target`
# unit in nix/home (awww-daemon, hyprpolkitagent, the dots-* app/action
# templates) is local-only and untouched.
{
  pkgs,
  lib,
  inputs,
  dotsFlake,
  tokyonightModules,
}:
let
  settings = (import ../nix/system/defaults.nix) // {
    username = "test";
    hostname = "test";
    disks = [ "/dev/vda" ];
    swapSize = "1G";
    aiClaude = false;
    aiCodex = false;
    aiOllama = false;
  };

  # Mirrors mkTokyonight's specialArgs (flake/nixos.nix) verbatim, taken from
  # the flake's own packages rather than rebuilt.
  # `chromaleon` is REQUIRED here even though mkTokyonight's own specialArgs
  # does not carry it: nix/modules/system/users.nix destructures it as a
  # plain (non-`?`) argument and threads it into the "test" user's
  # `extraSpecialArgs`, and nix/home/base/gnome-extensions.nix destructures
  # it again on the home-manager side. NixOS's module-argument machinery
  # (`lib.modules.applyModuleArgs`) only throws once a missing argument is
  # actually FORCED — `f (args // extraArgs)`, where `extraArgs.<name>` is a
  # lazy `args.<name> or config._module.args.<name>` thunk — so an eval that
  # never reaches gnome-extensions.nix's use of `chromaleon` (every
  # `flake/checks.nix` check over `nixosConfigurations.tokyonight` today)
  # never notices it is missing there. Building the real home-manager
  # activation package — which this test does — reaches it. Worth flagging
  # upstream: `flake/nixos.nix`'s specialArgs appears to have the same gap.
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

  # Test-only: autologin + a headless GL path + boot.nix's disk-dependent
  # bit turned off + the two network home-manager units named above. Never
  # merged into the real tokyonight closure — this module exists only in
  # this file's own `nodes.machine`.
  testOverrides =
    { config, lib, ... }:
    let
      # The literal `Exec=` line nixpkgs' hyprland module
      # (`programs.hyprland.withUWSM = true`, desktop.nix) writes into
      # `share/wayland-sessions/hyprland-uwsm.desktop` for this session —
      # read back from the REAL generated desktop entry at eval time
      # (`config.services.displayManager.sessionData.desktops` is a real
      # derivation; `readFile` on it is import-from-derivation, so
      # evaluating this file now forces that derivation to build) rather
      # than frozen as a hardcoded literal. A frozen copy would go stale
      # the moment a uwsm/hyprland-module bump changes the invocation
      # shape, and the gate would then fail on that drift instead of on
      # whatever it is actually meant to catch — exactly the trap a
      # previous review round of this file was right to flag. Computing it
      # here means the gate always execs whatever the real desktop entry
      # says, today's shape included.
      hyprlandDesktopEntry = builtins.readFile
        "${config.services.displayManager.sessionData.desktops}/share/wayland-sessions/hyprland-uwsm.desktop";
      hyprlandExec = lib.pipe hyprlandDesktopEntry [
        (lib.splitString "\n")
        (builtins.filter (lib.hasPrefix "Exec="))
        lib.head
        (lib.removePrefix "Exec=")
      ];
    in
    {
      # greetd's `initial_session` is the standard NixOS-test autologin
      # shape for a greetd-managed compositor: skip regreet's greeter for
      # the VM's one and only session, straight into a session command —
      # see the "Known gap" section above for what this does and does not
      # cover. `services.greetd.settings` is a freeform (TOML-shaped)
      # attrset, so `initial_session` merges in ALONGSIDE the
      # `default_session` that `services.displayManager.regreet.enable`
      # (desktop.nix) already writes — regreet itself is untouched.
      #
      # `LIBGL_ALWAYS_SOFTWARE=1` is prefixed, and NOT `WLR_BACKENDS=headless
      # WLR_RENDERER=pixman` (tried first, and wrong): Hyprland >=0.40 does
      # not use wlroots' backend/renderer at all — it is built on its own
      # Aquamarine backend library, which has no headless backend and
      # ignores both wlroots env vars outright. Confirmed the hard way: with
      # those two set, Hyprland crashed instantly with `CBackend::create()
      # failed!`, and its (Aquamarine-prefixed) log showed the real chain —
      # DRM backend failed because libseat could not open a seat (no
      # /run/seatd.sock and the logind backend also refused, both traceable
      # to this VM having no virtual GPU at all, hence no VT/seat for logind
      # to hand out), then the Wayland-nested fallback failed too (nothing
      # to nest into). hyprwm/Hyprland#7917 is this exact crash, confirmed
      # upstream ("you dont have a seat manager running, which is a
      # dependency"). The fix is a real (if virtual) DRM device, not a
      # headless mode that no longer exists: `virtualisation.qemu.options`
      # below adds `-vga none -device virtio-gpu-pci` (the same device
      # nixpkgs' own nixos/tests/sway.nix uses, for the same reason —
      # without a GPU device that test needs `-vga std` swapped out for the
      # exact same complaint), which gives the kernel a real DRM/fbcon
      # device for logind to build a seat around. `LIBGL_ALWAYS_SOFTWARE=1`
      # then keeps Hyprland's OpenGL renderer on Mesa's llvmpipe/kms_swrast
      # software path on top of that device, since virtio-gpu-pci alone (no
      # `-gl` suffix) carries no real 3D acceleration.
      services.greetd.settings.initial_session = {
        command = "env LIBGL_ALWAYS_SOFTWARE=1 ${hyprlandExec}";
        user = "test";
      };

      # boot.nix's boot.zswap.enable = true asserts at least one physical
      # swap device; disko normally supplies one, and tokyonightModules
      # deliberately keeps boot.nix in the gate (see the header) for the
      # kargs it carries, not for zswap. boot.nix already forces this off
      # for `virtualisation.vmVariant` (nixos-rebuild build-vm); this test
      # node is a plain runNixOSTest node, which that mechanism does not
      # touch, so the same override is repeated here directly.
      boot.zswap.enable = lib.mkForce false;

      # firewalld.service and nftables.service both fail in this test VM,
      # root-caused from the full VM console (`nix log` on the failed drv):
      # `nftables-rules[541]: src/mnl.c:66: Unable to initialize Netlink
      # socket: Protocol not supported`, exit status 3/NOTIMPLEMENTED. This
      # VM's kernel has no NETLINK_NETFILTER, so nftables cannot even open a
      # socket, before any rule is parsed. firewalld starts fine and then
      # dies silently right after, because its backend is nftables
      # (hardening.nix sets networking.nftables.enable) and it cannot apply
      # a ruleset. Not Phase C's doing: neither `nf_tables` nor `nfnetlink`
      # is in the module blacklist, and hardening.nix's firewall config is
      # untouched by this phase's diff.
      #
      # Disabled here rather than excluded from assertion 5's failed-units
      # check: this VM kernel cannot run nftables at all, so there is no
      # firewall coverage to lose either way, and making the units absent
      # keeps that assertion honest for every other unit instead of quietly
      # ignoring two known-red ones forever.
      services.firewalld.enable = lib.mkForce false;
      networking.nftables.enable = lib.mkForce false;

      # Lingering: observed empirically, not assumed. Without this, greetd's
      # OWN session for "test" closes within a second of handing off to
      # uwsm (uwsm's `start` genuinely blocks on the compositor per its own
      # --help text, so this is greetd/logind session bookkeeping quirk, not
      # uwsm detaching) — logind then tears down /run/user/1000 and its bus
      # the moment no session remains for that uid, even though Hyprland
      # itself keeps running as an orphaned-but-alive systemd-managed
      # process tree. Every `su - test -c 'systemctl --user …'` in the
      # testScript then fails forever with "Failed to connect to user scope
      # bus", not because the session never started but because its runtime
      # directory was reclaimed out from under it. `loginctl enable-linger`
      # keeps user@1000.service (and /run/user/1000) alive independent of
      # active login sessions, matching how a real interactive desktop
      # login (which keeps at least one session open the whole time) never
      # hits this path.
      users.manageLingering = true;
      users.users.test.linger = true;

      # nix/modules/system/users.nix already does `home-manager.users.
      # ${config.dots.username} = import ../../home;` for every user
      # tokyonightModules creates, "test" included — no need to re-import
      # it here. Only the three overrides below belong in this block.
      home-manager.users.test = {
        # nix-flatpak's ENTIRE config (remotes, packages, the
        # flatpak-managed-install unit) hangs off this one switch — turning
        # it off here is cleaner than chasing the generated unit's name.
        services.flatpak.enable = lib.mkForce false;
        # dots-repo.nix sets Install.WantedBy at plain priority; only the
        # WantedBy needs suppressing; the unit stays defined, just unwanted.
        systemd.user.services.dots-clone.Install.WantedBy = lib.mkForce [ ];
        # nix/home/secrets/identity.nix decrypts secrets/git-identity.age at
        # home-manager ACTIVATION, using an SSH key that lives in the real
        # user's Bitwarden vault. This test VM has no such key (nor any
        # reason to have one — a fake "test" account has no identity to
        # decrypt), so `agenix.service` ran here and failed outright:
        # `agenix.service loaded failed failed agenix activation`, caught
        # live by assertion 5 ("nothing else broke"). That is a
        # test-environment gap, not a hardening regression, and not
        # something identity.nix itself should change: the module already
        # models "no secret available" as a first-class state via its
        # `hasSecret = builtins.pathExists secretFile` guard, and its own
        # header argues for failing closed rather than substituting a
        # default — the ciphertext genuinely exists in this checkout, so
        # `hasSecret` is genuinely true, and the module is correctly doing
        # its job of trying to decrypt something for a user it has no key
        # for. So this test makes the secret absent for the "test" user
        # specifically, the same state identity.nix already treats as
        # normal, rather than asking the module to pretend otherwise:
        # `age.secrets = lib.mkForce { };` empties agenix's home-manager
        # module's input, which is enough on its own to stop generating a
        # decrypt step for git-identity (agenix's activation script is
        # built per-secret; with none configured it has nothing to decrypt
        # and exits cleanly), without deleting the file from the checkout
        # or touching identity.nix.
        #
        # Deliberately NOT fixed by excluding "agenix.service" from
        # assertion 5's failed-units check: that would permanently blind
        # this gate to any REAL agenix breakage a later phase introduces
        # (a bad recipient key, a corrupted secrets.nix, systemd sandboxing
        # that breaks age's own file access) — exactly the class of silent
        # failure this gate exists to catch. Making the secret absent here
        # keeps that coverage for everyone except the one account that was
        # never supposed to have this secret in the first place.
        age.secrets = lib.mkForce { };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "session-boot";
  # Full personal home-manager profile (browsers, Zed, the Haskell toolchain,
  # AppArmor's ~223 stock profiles) substituted/built, then a real Hyprland +
  # UWSM + Quickshell boot on top. tests/default.nix:540 accepts equally long
  # waits for the ISO test; this one is not expected to need anywhere near
  # that, but a slow/uncached CI runner should not spuriously time out over
  # a substitution-bound closure.
  globalTimeout = 3 * 60 * 60;

  # `node.specialArgs`, not `nodes.machine._module.args`: the latter is
  # itself a config OPTION of the very module tree being resolved, and every
  # module below (starting with desktop.nix's `settings` argument) needs it
  # to resolve its OWN args, which is exactly the self-reference NixOS's
  # module system rejects as "infinite recursion encountered" (confirmed by
  # trying it). `node.specialArgs` (nixos/lib/testing/nodes.nix, upstream) is
  # the test framework's own hook for values needed "during the resolution
  # of module imports" — precisely this case.
  node.specialArgs = specialArgs;
  # runNixOSTest wires `node.pkgs` to the `pkgs` this file was called with,
  # which flips `node.pkgsReadOnly` on by default (nixos/modules/misc/nixpkgs
  # /read-only.nix) and pins `nixpkgs.config` to that outer pkgs' instance —
  # conflicting with core.nix's own `nixpkgs.config.allowUnfreePredicate`
  # (needed for claude-code/claude-desktop/obsidian/nvidia/steam) the moment
  # a real system module sets it. The option's own doc names this exact
  # case ("Set this to false when any of the nodes ... need to configure any
  # of the nixpkgs.* options").
  node.pkgsReadOnly = false;

  nodes.machine = {
    imports = tokyonightModules ++ [ testOverrides ];
    # A real (virtual) DRM device for Aquamarine/Hyprland to bind a seat and
    # a GL context to — see the long comment on `initial_session.command`
    # above for why this VM cannot run Hyprland without one. Mirrors
    # nixpkgs' own nixos/tests/sway.nix, which needs the identical swap for
    # the identical reason (its default is `-vga std`, this test framework's
    # is no display device at all; either way, no DRM node).
    virtualisation.qemu.options = [
      "-vga none"
      "-device virtio-gpu-pci"
    ];
    # Explicit, not a guess: nixpkgs' test framework defaults
    # `virtualisation.memorySize` to 1024 (MiB), and this file set nothing
    # else, so a first run of this gate booted a 1G VM with no swap running
    # the FULL desktop — greetd, NetworkManager, searxng, Hyprland,
    # Quickshell, Xwayland, portals, gcr, protonmail-bridge and friends all
    # resident at once. That is a materially bigger workload than
    # tests/default.nix's ISO-boot test, which only runs a single Quickshell
    # instance under cage with none of the above — and that test already
    # asks for 4096 (tests/default.nix:541; its lighter LiveISO installer
    # environment still gets 2048, tests/default.nix:260). The 1G default
    # OOMed here, and the test framework's own `panic_on_oom` (set by
    # nixpkgs' test instrumentation, not this repo, precisely so an OOMing
    # test VM fails loudly instead of silently losing processes) turned that
    # OOM into a kernel panic that reads, at first glance, like a kernel or
    # boot bug rather than an undersized VM. Matching the ISO test's number
    # rather than inventing a new one, since this gate's workload is at
    # least as heavy.
    virtualisation.memorySize = 4096;
  };

  # Console-and-backdoor assertions throughout: unlike the LiveISO
  # (iso-boot, console-only by design), this VM has the test framework's
  # usual root backdoor, so `machine.succeed`/`wait_for_unit` are available
  # rather than only serial-console text matching.
  #
  # Every `--user` query below shells out via `su - test -c '...'`
  # (mirroring nixpkgs' own nixos/tests/sway.nix) rather than the test
  # driver's `wait_for_unit(unit, user=...)` convenience: that path has a
  # documented failure mode right after a fresh login (nixos/tests/cosmic,
  # "Failed to connect to user scope bus") because it reuses one connection
  # attempt instead of retrying. A bare `su -c` inside `wait_until_succeeds`/
  # `retry` opens a fresh PAM session — and therefore a fresh bus
  # connection — on every retry, so an early D-Bus race resolves on its own
  # instead of wedging the assertion. "test" is the sole `isNormalUser`, so
  # it gets the first-normal-user uid 1000, same assumption nixpkgs' own
  # sway.nix and cosmic tests make about their single test account.
  testScript = ''
    su = "su - test -c 'XDG_RUNTIME_DIR=/run/user/1000 {}'".format

    machine.start()

    with subtest("greetd comes up and does not restart-loop"):
        machine.wait_for_unit("greetd.service")
        # Settle window: a restart-looping unit is intermittently "active"
        # between crashes, so give it time to show a nonzero NRestarts
        # rather than trusting the first is-active.
        machine.sleep(15)
        machine.succeed("systemctl is-active greetd")
        restarts = machine.succeed("systemctl show -p NRestarts --value greetd").strip()
        assert restarts == "0", (
            f"greetd restarted {restarts} time(s) during the settle window "
            "-- it is restart-looping, exactly the 9b069e8 failure mode"
        )

    with subtest("the hyprland-uwsm session reaches graphical-session.target"):
        machine.wait_until_succeeds(su("systemctl --user is-active graphical-session.target"))

    with subtest("quickshell is running, and its runtime-dir condition held"):
        # ConditionResult is checked on EVERY poll, before is-active, and a
        # "no" raises immediately instead of returning False: a condition
        # skip is a PERMANENT state (systemd never retries a
        # condition-skipped unit on its own), so if this were checked only
        # after `is-active` finally reported true -- or via a bare
        # `wait_until_succeeds(is-active)` first -- the exact failure this
        # assertion exists to catch (Hyprland not creating %t/hypr before
        # graphical-session.target tries to start quickshell) would instead
        # stall for `retry`'s full 15-minute default with a generic timeout,
        # never reaching the assertion at all. `retry` (test_driver.machine,
        # used bare the same way nixos/tests/sway.nix uses it) is what makes
        # an exception raised inside the polled function abort immediately
        # rather than being swallowed as "keep waiting", unlike
        # `wait_until_succeeds`/`PollingCondition`, which only look at a
        # shell exit code or a boolean return.
        def quickshell_started(last_chance):
            active_state = machine.succeed(
                su("systemctl --user show -p ActiveState --value quickshell")
            ).strip()
            condition_result = machine.succeed(
                su("systemctl --user show -p ConditionResult --value quickshell")
            ).strip()
            if condition_result == "no":
                raise Exception(
                    "quickshell's ConditionPathExists=%t/hypr failed: "
                    "Hyprland had not created its runtime directory by the "
                    "time graphical-session.target tried to start "
                    "quickshell, and systemd does not retry a "
                    "condition-skipped unit -- the session lost this race "
                    "permanently, and is-active alone would have reported "
                    "this as merely 'not yet' forever."
                )
            return active_state == "active"

        retry(quickshell_started)

    with subtest("quickshell actually reached the compositor (hyprctl layers)"):
        signature = machine.succeed(su("ls /run/user/1000/hypr")).strip()
        layers = machine.succeed(
            su(f"HYPRLAND_INSTANCE_SIGNATURE={signature} hyprctl layers")
        )
        # PanelWindow's default WlrLayershell.namespace is literally
        # "quickshell" (nix/home/desktop/quickshell/qml/bar/Bar.qml sets no
        # override), and hyprctl's plain-text layersRequest formats each
        # surface as "...namespace: {}..." (Hyprland src/ipc/s1/Commands.cpp)
        # -- so this string is what a bound, rendering layer-shell surface
        # looks like, not a guess. A Quickshell that started but failed to
        # bind zwlr_layer_shell_v1 passes the check above and fails this one.
        #
        # The prior "is it active" subtest only ever samples ActiveState
        # once, the instant it flips off "activating" -- exactly the same
        # blind spot the greetd subtest's explicit 15s settle window exists
        # to close (see its comment above), except quickshell's own unit
        # (Restart=on-failure, RestartSec=2) has no equivalent settle here.
        # A quickshell that crashes and restart-loops can be caught mid-"active"
        # by that first check and still be down again by the time this one
        # runs a few seconds later. So on failure, pull NRestarts and a
        # journal tail into the assertion message instead of leaving future
        # debugging to a second VM boot.
        # Three sources, because the obvious one is empty. `journalctl --user
        # -u quickshell` reported "No entries" on a real failure that had
        # NRestarts=2, i.e. the unit crashed twice and left nothing behind:
        # quickshell keeps its OWN log store and exposes it through a `log`
        # subcommand rather than writing crash detail to stderr, so the
        # journal only ever holds whatever Qt itself printed. Asking only the
        # journal is what made this race undiagnosable across several runs.
        #
        # `machine.execute` rather than `succeed` for all three: this block
        # runs when something is already wrong, and a diagnostic that raises
        # on its own would replace the real failure with its own.
        if "namespace: quickshell" not in layers:
            restarts = machine.succeed(
                su("systemctl --user show -p NRestarts --value quickshell")
            ).strip()
            _, journal = machine.execute(
                su("journalctl --user -u quickshell --no-pager -n 200")
            )
            # The system journal keyed on the user unit, in case the per-user
            # journal is the thing that is empty rather than the unit.
            _, sysjournal = machine.execute(
                "journalctl _SYSTEMD_USER_UNIT=quickshell.service --no-pager -n 200"
            )
            # Where the crash reason actually lives.
            _, qslog = machine.execute(su("quickshell log --no-color"))
            raise Exception(
                f"no quickshell layer-shell surface in `hyprctl layers`:\n{layers}\n"
                f"quickshell NRestarts={restarts}\n"
                f"journalctl --user -u quickshell:\n{journal}\n"
                f"journalctl _SYSTEMD_USER_UNIT=quickshell.service:\n{sysjournal}\n"
                f"quickshell log:\n{qslog}"
            )

    with subtest("nothing else broke"):
        failed = machine.succeed(su("systemctl --user --failed --no-legend")).strip()
        assert failed == "", f"failed user unit(s): {failed!r}"
        autorestart = machine.succeed(
            su("systemctl --user list-units --state=auto-restart --no-legend")
        ).strip()
        assert autorestart == "", f"unit(s) stuck auto-restarting: {autorestart!r}"

        # System-scope, not just --user. A review of the pre-Phase-C tree
        # found `apparmor.service` failing on every single boot (see
        # nix/modules/system/hardening.nix's AppArmor comment for the
        # alphabetical-parser mechanism) while this gate stayed green,
        # because everything above only ever asked systemd's --user manager.
        # `machine.succeed` runs as root by default, unlike the `su`-wrapped
        # user-scope calls above, so no wrapper is needed here.
        system_failed = machine.succeed("systemctl --failed --no-legend").strip()
        assert system_failed == "", f"failed system unit(s): {system_failed!r}"

        # Explicit, not merely inferred from apparmor.service's absence
        # above: "not failed" also covers "masked" or "condition-skipped",
        # neither of which is what Part 4's deletion of the ~223 stock
        # profiles set out to prove. This is the actual claim being tested —
        # that removing the profiles the parser died on lets it finish
        # loading and reach "active" — so it gets its own assertion.
        apparmor_state = machine.succeed("systemctl is-active apparmor.service").strip()
        assert apparmor_state == "active", f"apparmor.service is not active: {apparmor_state!r}"
  '';
}
