# Declarative NixOS-option mapping derived from the retired konkrit firstboot
# hardening catalog (Gentoo era; see git history — 104 modules). Categories
# covered: sysctl net/kernel, boot params, coredump/ptrace, AppArmor,
# USBGuard, auditd, hidepid, firewall, sudo, kernel image protection,
# tmpfs /tmp.
#
# AppArmor ends up split three ways, so read all three before changing one.
# This module used to also load ~223 stock profiles from pkgs.apparmor-profiles
# in complain mode; that block is gone (Phase C of the hardening project —
# see docs/superpowers/specs/2026-09-08-hardening-design.md — found they were
# FHS-path profiles matching no Nix store target, AND that they were why
# apparmor.service failed on every boot: apparmor_parser loads profiles
# alphabetically, and the moment store-catchall installed the catch-all,
# the parser's own next exec attached to it and hit `deny capability
# mac_admin`, aborting the load partway through). `packages` stays: it is,
# in nixpkgs' own words, AppArmor's *include path*, and every hand-written
# profile in apparmor.nix and apparmor-store.nix leans on `include
# <abstractions/base>`/`include <tunables/global>` resolving through it.
# The profiles that actually attach on NixOS are written against store paths:
# nix/modules/system/apparmor.nix holds the per-app profiles aimed at each
# browser's and editor's resolved ELF, and nix/modules/system/apparmor-store.nix
# holds the `mkStoreProfile` generator plus the store-wide complain-mode
# catch-all whose denial log feeds `dots-sandbox triage`. flake/nixos.nix
# imports all three together; none of them is sufficient alone.
#
# A second pass in 2026-09 closed the findings from `lynis audit system`
# (baseline: hardening index 70). Not everything Lynis asks for is right on
# NixOS, and the items deliberately left alone are commented where they sit
# rather than silently ignored, so the next audit does not re-litigate them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Ported from secureblue (Phase C); see each data file's own header for
  # provenance and the REUSE.toml overrides that license them separately
  # from this repo's default.
  #
  # The 9p family (9p, 9pnet, 9pnet_fd, 9pnet_rdma, 9pnet_usbg,
  # 9pnet_virtio, 9pnet_xen) is filtered back out here, NOT in the ported
  # data file, because this is a divergence from secureblue worth stating
  # plainly rather than silently baking into the "faithful copy" data.
  # secureblue is bare-metal-only and never has to reckon with this:
  # `pkgs.testers.runNixOSTest` (which `tests/session-boot.nix`,
  # `tests/sandbox.nix` and `nix run .#nix-smoke` all build on) shares the
  # host's /nix/store into the test VM over virtio-9p, and `install 9pnet
  # /bin/false` breaks that transport unconditionally — confirmed the hard
  # way: it took `sysroot-nix-store.mount` down, which cascaded into
  # Initrd File Systems failing, emergency mode, and this repo's own
  # `panic-on-fail.service` turning that into a kernel panic before the
  # test driver's shell ever came up. Excluded machine-wide rather than
  # only for the test VM, because every NixOS VM test this repo builds
  # from `tokyonightModules` — not just `session-boot` — shares the same
  # exposure, and 9p was never reachable attack surface on real hardware
  # to begin with (nothing here ever asks for it outside a VM test
  # harness), so nothing is actually given up by leaving it loadable.
  #
  # `joydev` is filtered back out the same way, for the opposite reason:
  # this config deliberately enables Steam (nix/modules/desktop/steam.nix,
  # and ia32_emulation is kept in boot.kernelParams above specifically for
  # it), and blacklisting the joystick input layer under it is
  # self-defeating — no gamepad shows up at /dev/input/js* for any game to
  # see. secureblue is not running Steam on this machine's hardware, so its
  # blanket blacklist doesn't have to reckon with this either.
  secureblueModuleBlacklist = builtins.filter (
    mod: !lib.hasPrefix "9p" mod && mod != "joydev"
  ) (import ../../data/module-blacklist.nix);
  secureblueFramebufferBlacklist = import ../../data/framebuffer-blacklist.nix;
in
{
  security.forcePageTableIsolation = true;

  # GrapheneOS hardened_malloc, system-wide (Phase B). secureblue injects
  # `libhardened_malloc.so` four separate ways — /etc/profile.d,
  # /usr/lib/environment.d, systemd's `[Manager] DefaultEnvironment=`, and
  # PAM's pam_env.conf — because Fedora Atomic has no single hook that
  # reaches every process. NixOS does: this one option makes the
  # `nixos/modules/config/malloc.nix` module write the resolved
  # `libhardened_malloc.so` path into `/etc/ld-nix.so.preload`, and nixpkgs'
  # glibc carries a NixOS-specific patch
  # (`pkgs/development/libraries/glibc/dont-use-system-ld-so-preload.patch`)
  # that makes `elf/rtld.c` read exactly that path — unconditionally, for
  # every dynamically-linked exec on the system — in place of the upstream
  # `/etc/ld.so.preload`. One option reaches everything secureblue's four
  # hooks reach together; `security.apparmor.includes."abstractions/base"`
  # picks up the read grant for it automatically (same module), so the
  # per-app profiles in apparmor.nix/apparmor-store.nix need no edit.
  #
  # Full variant (`graphene-hardened`), not `graphene-hardened-light`: the
  # divergence table in the design spec lists secureblue's own allocator as
  # the parity target, and secureblue runs the full variant — the light one
  # exists upstream as a performance compromise, not as secureblue's actual
  # baseline, so choosing it here would still leave a gap to close rather
  # than closing it.
  #
  # The RLIMIT_AS trap: hardened_malloc reserves guard pages across a much
  # larger virtual-address range than it will ever commit, so a process
  # under a real `RLIMIT_AS` ceiling can fail `mmap`/`brk` with ENOMEM long
  # before it is anywhere near its actual memory budget. secureblue ships a
  # dedicated `libno_rlimit_as.so` LD_PRELOAD shim for exactly this, and
  # NixOS has no equivalent option. Investigated rather than assumed:
  #   - `grep -rn LimitAS= nix/` finds nothing; no unit in this repo sets it.
  #   - nixpkgs' own modules only reference `LimitAS` as a valid key name in
  #     `systemd.nspawn`'s option-name allowlist
  #     (nixos/modules/system/boot/systemd/nspawn.nix) — nothing sets a
  #     value there either, and this repo defines no `systemd.nspawn.*`
  #     containers at all.
  #   - `security.pam.loginLimits` (the NixOS option that would populate
  #     `/etc/security/limits.conf`, the other place an `as` ceiling could
  #     come from) is never touched anywhere in nix/, so it stays at its
  #     default `[ ]` — no PAM-imposed AS limit either.
  #   - systemd's own compiled-in default for `DefaultLimitAS=` is
  #     "infinity" unless a unit or `[Manager]` override changes it, and
  #     nothing here touches `systemd.extraConfig` or any `[Manager]`
  #     section.
  # Net finding: nothing in this closure sets RLIMIT_AS, by any of the three
  # mechanisms that could plausibly do it, so the failure mode
  # `libno_rlimit_as.so` exists to paper over should not be reachable here
  # today. This is a closure-wide grep-and-source-read, not a boot-tested
  # guarantee — a future unit (or a nixpkgs module bump) that adds
  # `LimitAS=` to some service would silently reintroduce the trap, so a
  # `LimitAS=` grep belongs in the review checklist for any new hardened
  # unit from here on. If a service starts failing allocations with ENOMEM
  # after this lands, that grep is the first thing to rerun, and
  # `graphene-hardened-light` (touches far fewer guard pages) is the
  # documented fallback — flip the `provider` value below, nothing else
  #
  # Steam (nix/modules/desktop/steam.nix), checked because hardened_malloc is
  # exactly the class of allocator known to trip up closed-source game
  # engines: it does NOT inherit this. `programs.steam` builds on
  # `buildFHSEnv`, whose bubblewrap sandbox
  # (pkgs/build-support/build-fhsenv-bubblewrap/default.nix in this pinned
  # nixpkgs) gives the FHS environment its own private `/etc` — a fresh
  # tmpfs populated only from the FHS closure's own `/etc` plus a hardcoded
  # `etcBindEntries` allowlist (passwd, resolv.conf, localtime, ssl/certs,
  # pam.d, and so on). `ld-nix.so.preload` is not on that list and the
  # sandboxed `/etc` is never a bind-mount of the real one, so the file the
  # patched glibc above reads is simply absent inside Steam's sandbox; its
  # `__access() == 0` check fails and it loads nothing extra, the same as
  # on unpatched glibc with no preload file at all. Confirmed by reading
  # that exact script for this pinned nixpkgs revision, not assumed — Steam
  # is currently untestable here anyway (dots.steam.enable stays "auto" and
  # the committed `{}` facter stub reports no GPU, so `programs.steam.enable`
  # never activates in this evaluated closure to begin with).
  # depends on which variant is loaded.
  environment.memoryAllocator.provider = "graphene-hardened";

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "kernel.yama.ptrace_scope" = 2;
    "kernel.kexec_load_disabled" = 1;
    "kernel.sysrq" = 0;
    "fs.protected_hardlinks" = 1;
    "fs.protected_symlinks" = 1;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    # Lynis KRNL-6000 wants rp_filter=1 (strict). It stays at 2 (loose) on
    # purpose: this machine is multi-homed across libvirt bridges and a VPN,
    # and strict mode drops the return path of any asymmetric route, which
    # breaks both. Loose still discards packets with no route back at all.
    "net.ipv4.conf.all.rp_filter" = lib.mkForce 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    # Unprivileged loading of TTY line disciplines has a long history of local
    # privilege escalation (CVE-2017-2636 and friends). Nothing here needs it.
    "dev.tty.ldisc_autoload" = 0;
    # Log packets with impossible source addresses. Costs some journal volume
    # and is the only way to notice spoofing attempts at all.
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;

    # From here down: secureblue's sysctl baseline (reference/55-hardening.conf
    # in this project's SDD notes) that this machine lacked. Excluded on
    # purpose, per docs/superpowers/specs/2026-09-08-hardening-design.md
    # ("Phase C"): kernel.panic=-1 (R8) would turn a kernel splat into an
    # instant reboot with no readable dmesg; the ARP-hardening quartet
    # (arp_filter/arp_ignore/shared_media/drop_gratuitous_arp, R9) would be
    # incoherent next to rp_filter's deliberate mkForce 2 above, for the same
    # multi-homed-libvirt/VPN reason; kernel.yama.ptrace_scope is already 2
    # here, stricter than secureblue's 1.

    # perf_event_open() can leak kernel addresses and time hardware side
    # channels; 3 is the most restrictive setting (unprivileged users get
    # nothing from it at all).
    "kernel.perf_event_paranoid" = 3;
    # io_uring has been a disproportionate source of kernel-exploit primitives
    # (see the kCTF writeups linked in the reference file); 2 disables it
    # entirely, including for CAP_SYS_ADMIN.
    "kernel.io_uring_disabled" = 2;
    # Panic the kernel after this many oopses/warnings rather than allowing a
    # bug to be poked at indefinitely in small, deniable increments.
    "kernel.oops_limit" = 100;
    "kernel.warn_limit" = 100;
    # Route core dumps to a no-op instead of a file: a setuid process's or a
    # secret-holding process's memory never touches disk this way. The
    # reference value is a bare `/bin/false`, which does not exist on
    # NixOS (only `/bin/sh` and `/usr/bin/env` are guaranteed) — the kernel
    # would try to exec a path that is not there instead of the intended
    # no-op, so this points at the real store path.
    "kernel.core_pattern" = "|${pkgs.coreutils}/bin/false";
    # Never core-dump a setuid/setgid process — the classic route to reading
    # a privileged binary's memory back out as your own user.
    "fs.suid_dumpable" = 0;
    # binfmt_misc lets userspace register new "this file extension execs as
    # that interpreter" handlers at runtime; nothing here needs that surface.
    "fs.binfmt_misc.status" = 0;
    # Restrict userfaultfd() to CAP_SYS_PTRACE. Unprivileged access to it is a
    # well-worn primitive for winning kernel heap-spray/UAF races by holding a
    # page fault open on demand.
    "vm.unprivileged_userfaultfd" = 0;
    # Maximum mmap ASLR entropy, 64-bit and 32-bit-compat respectively.
    "vm.mmap_rnd_bits" = 32;
    "vm.mmap_rnd_compat_bits" = 16;
    # Refuse mappings in the bottom 64KiB of the address space, closing the
    # classic NULL-pointer-dereference-to-arbitrary-write escalation.
    "vm.mmap_min_addr" = 65536;
    # TCP timestamps leak host uptime (a fingerprinting and side-channel
    # surface) for no benefit this network needs.
    "net.ipv4.tcp_timestamps" = 0;
    # RFC 1337: ignore RSTs that arrive for a TIME-WAIT connection, closing
    # the sequence-number-guessing TIME-WAIT assassination class.
    "net.ipv4.tcp_rfc1337" = 1;
    # Never answer ICMP/ICMPv6 echo requests — removes ping-based host
    # discovery and the smurf/ping-flood surface outright, stricter than only
    # ignoring broadcast pings.
    "net.ipv4.icmp_echo_ignore_all" = 1;
    "net.ipv6.icmp.echo_ignore_all" = 1;
    # Prefer IPv6 privacy (temporary) addresses over the stable EUI-64 one for
    # outbound connections, so a device's IPv6 suffix cannot be used to track
    # it across networks.
    "net.ipv6.conf.all.use_tempaddr" = 2;
    # mkForce, not a plain value: nixpkgs' own
    # nixos/modules/tasks/network-interfaces.nix already sets this same key
    # (from networking.tempAddresses, default "default" → sysctl "2") as a
    # PLAIN definition, not mkDefault, so a second plain `= 2;` here collides
    # with it — "defined multiple times" — even though both resolve to the
    # same value. Forcing pins the intent explicitly rather than relying on
    # coincidence between this file and networking.tempAddresses' default.
    "net.ipv6.conf.default.use_tempaddr" = lib.mkForce 2;
  };

  # secureblue's kernel command line (reference/10-secureblue.toml in this
  # project's SDD notes), 34 entries, ported here except for the rulings
  # docs/superpowers/specs/2026-09-08-hardening-design.md ("Phase C") records:
  #   - module.sig_enforce=1 and lockdown=confidentiality (R1/R2) move to
  #     Phase A. Between now and then this machine runs the stock kernel with
  #     unsigned modules; sig_enforce there would make the kernel refuse
  #     every module load and strand the machine.
  #   - nosmt is not adopted — SMT stays on (project decision).
  #   - loglevel stays at the repo's existing 3 (R10), not secureblue's 0, so
  #     a panic's tail stays readable for Phase A's CFI debugging.
  #   - ia32_emulation=0 is not set: this repo enables Steam, whose runtime is
  #     32-bit (R11).
  #   - pti=on is not repeated: security.forcePageTableIsolation = true above
  #     already emits it (nixpkgs' nixos/modules/security/misc.nix).
  #   - kvm-intel.vmentry_l1d_flush=always is not repeated: security.
  #     virtualisation.flushL1DataCache = "always" below already covers it.
  boot.kernelParams = [
    "init_on_alloc=1"
    "init_on_free=1"
    "page_alloc.shuffle=1"
    "randomize_kstack_offset=on"
    "slab_nomerge"
    "hash_pointers=always"
    "intel_iommu=on"
    "iommu.passthrough=0"
    "iommu.strict=1"
    # The one entry here with real hardware-breakage potential: forcing IOMMU
    # translation for every device can wedge a peripheral whose driver
    # assumes it may DMA to physical addresses directly. First thing to drop
    # if a device misbehaves after this lands.
    "iommu=force"
    "kvm.mitigate_smt_rsb=1"
    "l1d_flush=on"
    "l1tf=full,force"
    "proc_mem.force_override=ptrace"
    "random.trust_bootloader=off"
    "random.trust_cpu=off"
    "rd.emergency=halt"
    "rd.shell=0"
    "slab_debug=FZ"
    "spec_store_bypass_disable=on"
    "spectre_v2=on"
    "ssbd=force-on"
    "systemd.ssh_auto=no"
    "vdso32=0"
    "vsyscall=none"
  ];

  security.virtualisation.flushL1DataCache = "always";
  systemd.coredump.enable = false;
  # This used to also load every stock profile under pkgs.apparmor-profiles
  # (~223 of them) in complain mode, through a `policies` attribute built by
  # `readDir`-ing that package's profile directory. Gone as of Phase C
  # (docs/superpowers/specs/2026-09-08-hardening-design.md): those are
  # upstream FHS-distribution profiles attaching to paths like
  # /usr/bin/brave, which do not exist on NixOS, so they matched nothing —
  # AND they were the reason `apparmor.service` failed on every boot.
  # apparmor_parser loads profiles alphabetically; the moment it reached
  # `store-catchall` (nix/modules/system/apparmor-store.nix) it installed
  # that catch-all, and the parser's own *next* exec — itself a Nix store
  # path — immediately attached to the catch-all it had just loaded and hit
  # its `deny capability mac_admin`, aborting the rest of the load
  # (`stress-ng` sorts right after `store-catchall`, so everything from
  # there on alphabetically never loaded). Deleting the stock profiles fixes
  # this as a side effect of removing dead weight: with them gone, nothing
  # alphabetically follows the catch-all inside this module's own load
  # order, and `apparmor.service` reaches `active`.
  #
  # `packages` STAYS. It is, in nixpkgs' own words, "List of packages to be
  # added to AppArmor's include path" — nothing to do with the deleted
  # `policies` block. It is what makes `include <abstractions/base>` and
  # `include <tunables/global>` resolve for every hand-written profile in
  # apparmor.nix and apparmor-store.nix; dropping it breaks both of those
  # outright.
  security.apparmor = {
    enable = true;
    packages = [ pkgs.apparmor-profiles ];
  };
  services.firewalld.enable = true;
  # No `DefaultZone` override here on purpose. nixpkgs' firewall-firewalld.nix
  # sets `services.firewalld.settings.DefaultZone = lib.mkDefault
  # "nixos-fw-default"` and builds that zone's rules out of
  # `networking.firewall.{allowedTCPPorts,allowedUDPPorts,trustedInterfaces,
  # rejectPackets}` below. A plain-literal override here used to win over
  # that `mkDefault` at normal priority, which made the entire
  # `networking.firewall` block dead code: it kept configuring a zone no
  # interface was bound to any more, while every real interface fell into
  # firewalld's built-in bare `drop` zone instead — a zone this repo
  # configures no exceptions for anywhere. mDNS, IPv6 router advertisements
  # and the DHCPv4 raw-socket DISCOVER/OFFER handshake all died there, on a
  # machine that is multi-homed across libvirt bridges and a VPN (see the
  # rp_filter comment above). Also worth recording: `networking.firewall.backend`
  # auto-resolves to `firewalld` whenever `services.firewalld.enable` is set,
  # so `networking.nftables.enable` below is inert here — there is no
  # dual-writer conflict, which is why the fix is one deletion and not a
  # rework.
  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;

    # Block unsolicited inbound connections.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];

    # Do not trust any interfaces.
    trustedInterfaces = [ ];

    # Optional: silently drop packets rather than reject them.
    rejectPackets = false;
  };
  # Escalation is `run0` first, sudo-rs second.
  #
  # `run0` (a systemd-run alias, systemd >= 256) asks PID 1 to start the
  # command as a transient unit and authenticates through polkit. It owns no
  # setuid bit and inherits nothing from the calling shell — no environment,
  # no ambient capabilities, a fresh PTY. That property is why it leads here
  # rather than because it is newer: this machine has already had every
  # setuid binary under /run/wrappers/bin stop working at once. Commit
  # 9b069e8 records it — `store-catchall` went to enforce, execute vanished
  # for everything outside the store, and sudo, su, pkexec, passwd and
  # newuidmap all died together while greetd restart-looped. An escalation
  # path that never touches /run/wrappers survives that class of failure.
  #
  # sudo-rs deliberately STAYS enabled underneath. run0 depends on polkit,
  # dbus and a live PID 1 answering on the system bus, which is a longer
  # chain than a setuid binary needs; if any link breaks, sudo-rs is the way
  # back in. Two mechanisms with disjoint failure modes is the point. The day
  # run0 has proven itself here, dropping sudo-rs is one line — but it is a
  # separate, deliberate change, not a side effect of preferring run0.
  security = {
    protectKernelImage = true;
    sudo.enable = false;
    sudo-rs = {
      enable = true;
      execWheelOnly = true;
      # Passwordless for all wheel members. NB: this leaves the FIDO2 sudo PAM
      # auth wired in desktop.nix dormant — NOPASSWD skips PAM authentication,
      # so the security key never gets a chance to prompt. Flip this to true to
      # switch to key-gated sudo (tap key instead of passwordless) instead.
      wheelNeedsPassword = false;
    };

    # Without this, run0 would be strictly worse to use than the sudo-rs
    # sitting next to it: `manage-units` defaults to auth_admin, so every
    # escalation would prompt while `sudo` stayed passwordless, and nobody
    # would reach for run0 twice.
    #
    # This grants no privilege that is not already granted. wheel has
    # passwordless sudo-rs on this machine, i.e. unauthenticated root
    # already; a rule that lets the same group manage units without
    # re-authenticating hands over nothing new. State that plainly rather
    # than pretending the rule is narrow: `manage-units` covers starting and
    # stopping ANY system unit, not just the transient one run0 creates,
    # because systemd exposes no run0-specific action to scope it to.
    #
    # The corollary is that flipping wheelNeedsPassword back to true does NOT
    # by itself restore a password prompt everywhere — this rule has to go
    # with it, or run0 remains the passwordless hole in an otherwise
    # key-gated setup.
    polkit.extraConfig = ''
      // run0 (systemd-run) for wheel, without re-authenticating.
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
  boot.tmp.useTmpfs = true;

  # secureblue's module policy (reference/secureblue-modprobe.conf and
  # reference/secureblue-framebuffer.conf in this project's SDD notes; the
  # 4-entry Lynis NETW-3200 list this replaced — dccp, sctp, rds, tipc — is a
  # strict subset of it). Deliberately `extraModprobeConfig`, not
  # `boot.blacklistedKernelModules`: NixOS's option only emits a `blacklist`
  # directive, which stops a module from autoloading on a device/alias match
  # but does nothing to stop an explicit `modprobe <mod>` or a udev rule that
  # names it directly. secureblue's own `install <mod> /bin/false` intercepts
  # every load path, including that one, by replacing the module's install
  # command outright. Matching that exactly rather than silently downgrading
  # to the weaker form is the point — see nix/data/module-blacklist.nix and
  # nix/data/framebuffer-blacklist.nix for the ported lists themselves.
  # Bluetooth (`bluetooth`, `btusb`, `bluetooth_6lowpan`) is included on
  # purpose: nix/modules/system/form-factor.nix now sets
  # hardware.bluetooth.enable = false unconditionally, and this closes the
  # module path a stray `modprobe bluetooth` could still take around that.
  #
  # `${pkgs.coreutils}/bin/false`, not a bare `/bin/false`: the reference
  # config is written for Fedora, where that path exists; NixOS ships only
  # `/bin/sh` and `/usr/bin/env`. The block still held with the bare path —
  # kmod runs `install`'s command through `sh -c`, and `sh` itself exits 127
  # when the target is missing — but every refused load logged `sh:
  # /bin/false: No such file or directory` instead of a clean no-op.
  boot.extraModprobeConfig = lib.concatMapStrings (
    mod: "install ${mod} ${pkgs.coreutils}/bin/false\n"
  ) (
    secureblueModuleBlacklist ++ secureblueFramebufferBlacklist
  );

  # USB-1000 / BadUSB. `implicitPolicyTarget = "block"` refuses anything not
  # already known, and `presentDevicePolicy = "allow"` grandfathers in whatever
  # is plugged in when the daemon starts, so the first boot after this lands
  # does not fight the hardware.
  #
  # An earlier version of this comment claimed the machine could not lock
  # itself out because its keyboard was `AT Translated Set 2 keyboard` on PS/2
  # and its touchpad `ELAN0524:00` on i2c, so nothing traversed USB. That is
  # true of the laptop and false of `matthiaspc`, which drives this same
  # closure: there the keyboard is a `Massdrop Inc. ALT Keyboard` sitting
  # BEHIND a `Massdrop Hub`, and the mouse a `Corsair NIGHTSWORD RGB`. Both
  # are USB, which is precisely the "one replug away from an unusable console"
  # case the old comment warned others about while asserting it did not apply
  # here.
  #
  # `presentDevicePolicy = "allow"` still grandfathers in whatever is attached
  # when the daemon starts, so a clean boot was never the exposure. The
  # exposure is everything after it: a replug, a hub power cycle, a KVM
  # switch, or any re-enumeration hits `implicitPolicyTarget = "block"` and
  # takes the keyboard with it.
  #
  # The `rules` below close that. They are the input chain and nothing else,
  # listed parent-first because a rule for a device behind a blocked hub
  # grants nothing — the hub has to come back before the keyboard hanging off
  # it can. Deliberately NOT a general "allow all HID": BadUSB attacks work by
  # claiming to be a keyboard, so allowing the class would surrender exactly
  # what USBGuard is here to hold. Everything else on this box — the audio
  # device, MSI Mystic Light, Bluetooth, any USB storage — stays subject to
  # the implicit block once re-enumerated, and gets approved through the
  # daemon (see IPCAllowedUsers) or gains a line here.
  services.usbguard = {
    enable = true;
    implicitPolicyTarget = "block";
    presentDevicePolicy = "allow";
    rules = ''
      allow id 1d6b:0002 # Linux xHCI root hub (USB 2.0) — the input chain hangs off this one
      allow id 1d6b:0003 # Linux xHCI root hub (USB 3.0)
      allow id 04d8:eec5 # Massdrop Hub — the ALT keyboard's parent; blocking it orphans the keyboard
      allow id 04d8:eed3 # Massdrop Inc. ALT Keyboard
      allow id 1b1c:1b5c # Corsair NIGHTSWORD RGB Gaming Mouse
    '';
    # The desktop needs to talk to the daemon to approve a new device without
    # a root shell.
    IPCAllowedUsers = [
      "root"
      config.dots.username
    ];
  };

  # Phase B, Part 3: faillock and pwquality, matched to the values measured
  # off secureblue's /etc/security/{faillock,pwquality}.conf.
  #
  # THE INTERACTION TO KEEP IN MIND (see hardening.nix's own `sudo-rs`
  # block above): `security.sudo-rs.wheelNeedsPassword = false` means wheel
  # escalation never enters PAM's auth stack at all — there is no password
  # prompt for either of these modules to ever see. Both settings below
  # govern LOGIN (console `login`, the `ly`/`hyprlock` PAM services already
  # wired for FIDO2 in desktop.nix, and password *changes* via `passwd`),
  # never escalation. Do not read their presence here as "sudo is
  # rate-limited" or "sudo enforces a strong password" — neither is true on
  # this machine today.
  #
  # faillock: NixOS's PAM module has a `logFailures` option per service that
  # inserts `pam_faillock.so` into that service's `auth` stack, but no
  # dedicated option for the module's own tunables (secureblue's `deny`,
  # `unlock_time`, etc.) — those live in `/etc/security/faillock.conf`,
  # which pam_faillock.so reads directly, distro-agnostically, whenever no
  # inline module argument overrides it. So this is two parts: the file,
  # and switching the option on for the same three services desktop.nix
  # already treats as "the login surfaces" (u2fAuth is wired identically on
  # exactly these three).
  environment.etc."security/faillock.conf".text = ''
    # Ported from secureblue (reference/55-hardening.conf-adjacent
    # /etc/security/faillock.conf in this project's SDD notes).
    deny = 50
    unlock_time = 86400
    even_deny_root
    audit
  '';
  security.pam.services = {
    login.logFailures = true;
    ly.logFailures = true;
    hyprlock.logFailures = true;
  };

  # pwquality: same story as faillock — one config file pam_pwquality.so
  # reads directly — but with one extra step. Unlike faillock, NixOS's PAM
  # module has NO built-in `enable`-style knob for pam_pwquality at all, and
  # (confirmed by reading nixos/modules/security/pam.nix directly) it never
  # declares a `passwd` PAM service by default either — nothing here
  # invokes pam_unix.so's password-changing stage today, so dropping only
  # the conf file would be inert: no module reads it. Declaring the service
  # is what actually wires a password-change stack into existence, matching
  # what `passwd`(1) expects to find at /etc/pam.d/passwd.
  #
  # `requisite`, not `required`: pwquality must reject a weak password
  # BEFORE pam_unix.so's own password rule ever runs, or a rejected password
  # would still fall through to being hashed and stored. Ordered via the
  # exact relative-order pattern this module's own header comment
  # documents (`rules.auth.foo.order = …unix.order + 10`) — here `- 50`
  # instead, to land before "unix" (order 10200 for the password stack,
  # i.e. `10000 + index*100` with unix as the second autoOrderRules entry)
  # rather than after it. `${pkgs.libpwquality.lib}` is deliberate, not
  # `${pkgs.libpwquality}`: this package splits `pam_pwquality.so` into its
  # `lib` output specifically, confirmed by building it against this pinned
  # nixpkgs — the default "out" output carries only `pwmake`/`pwscore` and
  # its own stock conf file, no `.so` at all.
  environment.etc."security/pwquality.conf".text = ''
    # Ported from secureblue (reference/55-hardening.conf-adjacent
    # /etc/security/pwquality.conf in this project's SDD notes).
    minlen = 15
    dcredit = -1
    ucredit = -1
    lcredit = -1
    ocredit = -1
    dictcheck = 1
    usercheck = 1
  '';
  security.pam.services.passwd.rules.password.pwquality = {
    control = "requisite";
    modulePath = "${pkgs.libpwquality.lib}/lib/security/pam_pwquality.so";
    order = config.security.pam.services.passwd.rules.password.unix.order - 50;
  };

  # ACCT-9628. Deliberately a short ruleset: auditd bills every matching
  # syscall, and a catch-all ruleset on a desktop buys noise rather than
  # evidence. These watch the files that grant access and the two operations
  # that change what the kernel itself will run.
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/group -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/sudoers.d -p wa -k privilege"
      "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules"
    ];
  };

  # FILE-6310-adjacent: hide other users' processes from unprivileged users, so
  # a compromised session cannot read another user's command lines and
  # /proc/<pid>/environ. `gid=proc` is the half that makes this survivable:
  # without a group allowed through, systemd-logind loses its view of sessions
  # and the desktop breaks in ways that only appear after a reboot.
  # The gid is pinned rather than left to auto-allocation because the mount
  # option below needs its numeric value at eval time, and an unpinned
  # users.groups entry evaluates to null there. 400 is free on both counts:
  # nixpkgs' static assignments in misc/ids.nix stop at 327, and NixOS allocates
  # dynamic system gids downward from 999.
  users.groups.proc.gid = 400;
  fileSystems."/proc" = {
    device = "proc";
    fsType = "proc";
    options = [
      "nosuid"
      "nodev"
      "noexec"
      "hidepid=2"
      "gid=${toString config.users.groups.proc.gid}"
    ];
  };
  systemd.services.systemd-logind.serviceConfig.SupplementaryGroups = [ "proc" ];

  # Not set, on purpose. Lynis KRNL-6000 wants kernel.modules_disabled=1, which
  # is a one-way switch: once flipped the kernel refuses every later module
  # load, so hotplugging anything, starting a VM, or bringing up a VPN after
  # boot fails with no way back short of a reboot. NixOS loads modules well past
  # early boot, so this would break the system rather than harden it.
}
