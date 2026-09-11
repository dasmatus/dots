# Hardening tokyonight: CFI/ThinLTO kernel, less surface, one shell, no bespoke sandbox

## Why

`nixosConfigurations.tokyonight` boots a stock `pkgs.linuxPackages_latest`
(`nix/modules/system/core.nix:13`) and hardens by sysctl and kernel parameter
alone. `nix/README.md:34-35` records two things as deliberately not ported
from the retired Gentoo configuration: the `hardened` kernel, and the
clang/LTO toolchain. This design ports both.

It also pays down three debts found while planning, each verified against a
file or against the live reference machine rather than assumed.

**The reference is measurable, because it is running.** The laptop this repo
is developed on runs secureblue (Fedora Atomic 44). Its kernel config, kernel
command line, sysctls, module blacklist, allocator wiring and Flatpak policy
were read off `/lib/modules/$(uname -r)/config`,
`/usr/lib/bootc/kargs.d/10-secureblue.toml`,
`/usr/lib/sysctl.d/55-hardening.conf`, `/usr/lib/modprobe.d/secureblue.conf`
and `~/.local/share/flatpak/overrides/global.save`. Every value in the
"Measured baseline" section below is quoted from those files, not recalled.

**The bespoke sandbox is redundant with what is already installed.**
`rust/dots-sandbox` is 9,279 lines, the largest crate in the repo. Its
`container` and `vm` tiers cannot start at all: nixpkgs' systemd is built
without BPF-LSM, `systemd-nsresourced` answers Varlink but refuses to hand
out a UID range, and `launch.rs` responds by running the app **fully
unconfined** with one `eprintln!` as the entire mitigation.
`tests/sandbox.nix` exists largely to document that failure. Its working
`bwrap` tier wraps eight CLI flake apps, four of which already require
`DOTS_SANDBOX=0` to function. Meanwhile `nix-flatpak` is already a flake
input, and `nix/home/base/flatpaks.nix` declares 25 Flathub refs including
Flatseal itself. **No GUI app routes through dots-sandbox at all** — the five
GUI entries in `nix/data/sandbox-policy.json` are orphans that nothing calls.

**Nothing on the machine is confined today.** Every profile in
`nix/modules/system/apparmor.nix` and the store catch-all in
`apparmor-store.nix` is `complain`-mode. The ~223 stock profiles loaded at
`hardening.nix:120-131` are FHS-path profiles (`/usr/bin/brave`) that can
never match a Nix store exec target; the module's own comment calls them
"loaded but confining nothing". And the Flatpak deny-by-default baseline that
makes secureblue's sandbox strong is written by *secureblue's own tooling on
the foreign host*. On tokyonight it does not exist, so the same Flatpaks run
on upstream's permissive manifests.

## Measured baseline: what secureblue actually does

### Kernel config

secureblue's kernel is **GCC-built** (`CONFIG_CC_IS_GCC=y`,
`CONFIG_CLANG_VERSION=0`), and therefore has **`CONFIG_LTO_NONE=y` and no
`CONFIG_CFI_CLANG`**. The entire Clang-only family (CFI, LTO, shadow call
stack, `ZERO_CALL_USED_REGS`) is compiled out as a toolchain consequence.

This is the single most important fact in the design: "match secureblue" and
"add CFI + ThinLTO" are **two distinct layers**. The second puts tokyonight
ahead of the daily driver rather than level with it.

What secureblue does set, and tokyonight must match:

```
INIT_ON_ALLOC_DEFAULT_ON=y     INIT_STACK_ALL_ZERO=y
HARDENED_USERCOPY=y            HARDENED_USERCOPY_DEFAULT_ON=y
BUG_ON_DATA_CORRUPTION=y       SCHED_STACK_END_CHECK=y
SLAB_FREELIST_RANDOM=y         SLAB_FREELIST_HARDENED=y
SHUFFLE_PAGE_ALLOCATOR=y       RANDOM_KMALLOC_CACHES=y
RANDOMIZE_BASE=y               RANDOMIZE_MEMORY=y
RANDOMIZE_KSTACK_OFFSET_DEFAULT=y
STRICT_KERNEL_RWX=y            STRICT_MODULE_RWX=y      DEBUG_WX=y
SECURITY_DMESG_RESTRICT=y      DEBUG_LIST=y
MODULE_SIG=y  MODULE_SIG_ALL=y  MODULE_SIG_SHA512=y
SECURITY_LOCKDOWN_LSM=y        SECURITY_LOCKDOWN_LSM_EARLY=y
LSM="lockdown,yama,integrity,selinux,bpf,landlock,ipe"
LEGACY_TIOCSTI is not set      COMPAT_BRK is not set     COMPAT_VDSO is not set
BPF_UNPRIV_DEFAULT_OFF=y
```

Two it notably does **not** set, which tokyonight will:
`INIT_ON_FREE_DEFAULT_ON` (secureblue forces it by karg instead),
`ZERO_CALL_USED_REGS`, and `STATIC_USERMODEHELPER`.

`CONFIG_LSM` is the one line that cannot port literally. secureblue is
SELinux plus IPE; NixOS gives AppArmor and Landlock. tokyonight uses
`lockdown,yama,integrity,apparmor,bpf,landlock`. Phase E depends on
`apparmor` being present in that string.

### Kernel command line

From `/usr/lib/bootc/kargs.d/10-secureblue.toml`, verbatim, 34 entries:

```
hash_pointers=always  init_on_alloc=1  init_on_free=1
intel_iommu=on  iommu.passthrough=0  iommu.strict=1  iommu=force
kvm_amd.sev=1  kvm_amd.sev_es=1  kvm_amd.sev_snp=1
kvm-intel.vmentry_l1d_flush=always  kvm.mitigate_smt_rsb=1
l1d_flush=on  l1tf=full,force  lockdown=confidentiality  loglevel=0
mitigations=auto,nosmt  module.sig_enforce=1  page_alloc.shuffle=1
proc_mem.force_override=ptrace  pti=on
random.trust_bootloader=off  random.trust_cpu=off
randomize_kstack_offset=on  rd.emergency=halt  rd.shell=0
slab_debug=FZ  slab_nomerge  spec_store_bypass_disable=on
spectre_v2=on  ssbd=force-on  systemd.ssh_auto=no  vdso32=0  vsyscall=none
```

tokyonight currently sets five of these
(`hardening.nix:65-71`: `init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1
randomize_kstack_offset=on slab_nomerge`) plus `mitigations=auto` from
`nix/system/defaults.nix:36-41`.

`nosmt` is **deliberately not adopted** — see Decisions.

### Sysctls

From `/usr/lib/sysctl.d/55-hardening.conf`. The ones tokyonight lacks:

```
kernel.perf_event_paranoid = 3      kernel.io_uring_disabled = 2
kernel.oops_limit = 100             kernel.warn_limit = 100
kernel.panic = -1                   kernel.core_pattern = |/bin/false
vm.unprivileged_userfaultfd = 0     vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16        vm.mmap_min_addr = 65536
fs.binfmt_misc.status = 0           fs.suid_dumpable = 0
net.ipv4.tcp_timestamps = 0         net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_all = 1   net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.conf.*.use_tempaddr = 2    net.ipv4.conf.*.arp_filter = 1
net.ipv4.conf.*.arp_ignore = 2      net.ipv4.conf.all.drop_gratuitous_arp = 1
net.ipv4.conf.*.shared_media = 0
```

### Deliberate divergences

These are places tokyonight knowingly differs, recorded so a future reader
does not "fix" them:

| Setting | secureblue | tokyonight | Why |
|---|---|---|---|
| `net.ipv4.conf.all.rp_filter` | `1` (strict) | `mkForce 2` (loose) | `hardening.nix` documents this as required for a multi-homed libvirt/VPN box |
| `kernel.yama.ptrace_scope` | `1` | `2` | tokyonight is stricter; secureblue leans on SELinux `deny_ptrace`, which has no AppArmor equivalent |
| MAC | SELinux + IPE, enforcing | AppArmor | Distribution reality, not a choice |
| USBGuard | installed, unit **disabled** | enabled with allowlist | tokyonight is already ahead |
| SMT | `nosmt` | SMT on | See Decisions |
| Allocator | hardened_malloc | hardened_malloc (Phase B) | Parity to be reached |

### hardened_malloc

secureblue injects `libhardened_malloc.so` plus `libno_rlimit_as.so` four
independent ways: `/etc/profile.d/hardened_malloc.sh`,
`/usr/lib/environment.d/40-hardened_malloc.conf`,
`/usr/lib/systemd/system.conf.d/40-hardened_malloc.conf`
(`[Manager] DefaultEnvironment=`), and
`/usr/share/secureblue/etc/security/pam_env.conf`.

`libno_rlimit_as.so` exists because hardened_malloc's guard-page design
inflates a process's *virtual* address space far past what an unmodified
`RLIMIT_AS` expects, so processes spuriously hit `ENOMEM`. Any port must
account for this.

NixOS provides this as one option:
`environment.memoryAllocator.provider = "graphene-hardened"`. There is no
built-in `libno_rlimit_as` equivalent.

### Flatpak global deny

From `~/.local/share/flatpak/overrides/global.save`, the baseline
`ujust harden-flatpak` writes:

```
[Context]
filesystems=!host-etc;!/mnt;!~/.bash_profile;!~/.bashrc;!/run/media;!home;
            !/media;!/home;!/var;!/run;!/var/home;!host;host-os:ro;
shared=!ipc;!network;
sockets=!cups;!gpg-agent;!inherit-wayland-socket;!pcsc;!pulseaudio;
        !session-bus;!ssh-auth;!system-bus;wayland;!x11;
devices=!all;dri;!input;!kvm;!shm;!usb;
features=!bluetooth;!canbus;!devel;!multiarch;!per-app-dev-shm;
persistent=.;
[Session Bus Policy] / [System Bus Policy]  — every name set to `none`
[Environment] LD_PRELOAD=<hardened_malloc path>; ELECTRON_OZONE_PLATFORM_HINT=auto
```

`host-os:ro` is granted **specifically** so the LD_PRELOAD'd allocator is
reachable inside the sandbox. It must survive the port (ruling R5).

`nix/home/base/flatpaks.nix:277` already confirms, from direct observation,
that a per-app positive grant re-opens a global deny — so the existing
per-app `overrides` block layers correctly on top of this baseline.

## Current state of tokyonight

- Kernel: `boot.kernelPackages = pkgs.linuxPackages_latest`, the only such
  declaration in the tree. No custom derivation, no `kernelPatches`, no
  `structuredExtraConfig`.
- Boot: Limine, **no Secure Boot, no UKI signing**, TPM2-bound LUKS on PCR 7,
  ephemeral tmpfs root via impermanence. `boot.nix:34` keeps
  `maxGenerations = 2`.
- Maintenance: `maintenance.nix:40-52` runs `nix flake update` +
  `nixos-rebuild boot` **daily**; `nix.gc` runs weekly with
  `--delete-older-than 0d`.
- Out-of-tree kernel modules: **none**. No ZFS, VirtualBox, v4l2loopback or
  DKMS anywhere. The one latent case is `nix/system/hosts.nix:35-43`, which
  enables `hardware.nvidia.open` when nixos-facter reports a `0x10de` device.
  The committed facter report is a stub, so it is inactive on the tracked
  config; the comment names a GTX 1660 SUPER (Turing TU116), i.e. the
  `matthiaspc` tower.
- Desktop: Hyprland via `programs.hyprland` + UWSM, greetd/regreet greeter,
  and a 141-file Quickshell tree that has already absorbed waybar, dunst,
  eww, rofi/`beamenu`, `hyprmon`, `wallpaper-tui` and `dots-osd` — those
  crates were **deleted**, not wrapped.
- Test coverage gap: `tests/session-units.nix` is **eval-only**, and
  `DOTS_UI_READY` in `tests/default.nix` belongs to the LiveISO installer's
  Quickshell running under `cage`. **Nothing boots the installed graphical
  session.** That is the gap incident `9b069e8` fell through, where flipping
  the AppArmor store catch-all to enforce killed every setuid binary under
  `/run/wrappers/bin` and restart-looped greetd.

## Decisions

| Question | Answer | Reasoning |
|---|---|---|
| Decomposition | One worktree, one branch, phased commits | Each phase independently revertable |
| tokyonight | Real hardware the user boots | Hardware validation available |
| Userspace LTO/CFI | Curated overlay, never a global `stdenv` swap | A global swap forfeits `cache.nixos.org` for the whole closure, the exact trade-off `nix/README.md:34` already rejected |
| Kernel mechanism | `.override` on the nixpkgs kernel | No custom `buildLinux`, no new flake input |
| CFI mode | **Enforcing from first boot** (`CFI_PERMISSIVE=n`) | Permissive mode is logging, not a mitigation |
| Upstream tracking | **Mainline from kernel.org**, `fetchurl`-pinned | Beyond nixpkgs' packaging lag |
| SMT | **Stays on** | Single-user laptop with no untrusted local tenants; `nosmt` would halve build throughput on a machine that now compiles its own kernel |
| Build location | **Local** | Codeberg cannot host the cache, see Open risks |
| Rust salvage | Extract `report.rs`, wire up `triage.rs` | Both are sandbox-orthogonal and serve this project |

## Phase designs

Execution order is **0 → C → B → E → D → A → A2**. Phase 0 first because a
boot oracle that arrives after the phases that can break the boot proves
nothing. Phase A last because it is the only phase that can fail to boot, so
landing it on an already-green tree leaves a bisect one suspect.

### Phase 0 — boot oracle

New `tests/session-boot.nix`, a `pkgs.testers.runNixOSTest` over
`nixosConfigurations.tokyonight`, asserting in order:

1. `greetd` reaches active and does not restart-loop
   (`systemctl show -p NRestarts greetd` stays `0` across a settle window).
2. The `hyprland-uwsm` session starts; `graphical-session.target` is active.
3. `systemctl --user is-active quickshell` is true. This is a real assertion,
   not a formality: the unit carries `ConditionPathExists=%t/hypr`, so it
   silently no-ops if Hyprland did not create its runtime dir.
4. `hyprctl layers` reports the bar's layer-shell surface — proving Quickshell
   obtained a Wayland connection rather than merely not crashing.
5. `systemctl --user --failed` is empty and no session unit is in
   `auto-restart`.

Wired into `tests/default.nix` and exposed through `flake/checks.nix` so the
weekly `vm` lane in `.forgejo/workflows/ci.yml` runs it.

**Every later phase must leave this green.** That is the enforceable form of
"make sure the Hyprland session actually starts".

### Phase C — surface removal and deletion

Adds the kargs and sysctls listed under "Measured baseline" that tokyonight
lacks, **except** `module.sig_enforce=1` and `lockdown=confidentiality`,
which move to Phase A (rulings R1 and R2 — on the stock kernel the first
makes the kernel refuse every module, and the second depends on config Phase
A supplies). `nosmt` is not adopted.

The 4-entry `boot.blacklistedKernelModules` at `hardening.nix:228-233` grows
to secureblue's 976-line `install <mod> /bin/false` set, expressed as a
generated Nix list.

Deletions:

| Target | Location | Why |
|---|---|---|
| `microvm` flake input | `flake.nix:30-43` | 14 lines of comment, zero code references anywhere in the repo |
| 223 stock AppArmor profiles | `hardening.nix:120-131` | FHS paths that match no store target; confine nothing |
| `geoclue2` + `localtimed` | `core.nix:93-104` | WiFi-SSID geolocation daemon; `gammastep` uses hardcoded coordinates |
| Bluetooth | `form-factor.nix:199` | Plus the module blacklist, matching secureblue |
| XWayland | `desktop.nix:74` | Whole GUI set is Wayland-native Flatpaks |
| `knownDesktopApps` | `flake/checks.nix:349-359` | Dead bookkeeping for orphaned policy entries |
| Hibernate action | `qml/launcher/Providers.qml:52` | Cannot work: `disko.nix:105` sets `randomEncryption` on swap, so there is no stable key to resume against |

`virtualisation.nix` gains a `dots.*` gate in the style `steam.nix` already
uses. `nix run .#nix-smoke` drives QEMU directly rather than libvirtd, so the
test harness is unaffected.

### Phase B — userspace hardening that costs no rebuild

1. `environment.memoryAllocator.provider = "graphene-hardened"`. Watch
   `RLIMIT_AS`, per the `libno_rlimit_as` note above.
2. Per-service systemd sandboxing on NetworkManager, ollama, postgresql and
   the `nixos-upgrade` unit that `maintenance.nix` itself flags as future
   work. The directive set is copied from
   `nix/modules/services/searxng.nix`, which already proves out in this repo
   (ruling R6), not invented per service.
3. faillock (`deny=50`, `unlock_time=86400`, `even_deny_root`) and pwquality
   (`minlen=15`, all four credit classes).
4. chrony with NTS, matching secureblue's GrapheneOS-derived config
   (`minsources 3`, `cmdport 0`, `noclientlog`).

Then, and only then, the curated Clang/ThinLTO/CFI overlay. Its scope is
honestly small: because every GUI app is already a Flatpak, tokyonight's
native network-facing surface is small. Per the repo's `c-compiler-preference`
skill the flags are `-fsanitize=cfi -flto=thin -fvisibility=hidden
-fuse-ld=lld` (all four or none) with `AR=llvm-ar RANLIB=llvm-ranlib`.

### Phase E — retire dots-sandbox

**Salvage first.** `report.rs` (1,006 lines) moves to its own small crate: it
is a read-only system-security dashboard (TPM, IOMMU, CPU mitigations, Secure
Boot, FIDO2, kernel lockdown, AppArmor profile count, LUKS, mic/camera via
`pw-dump`) that powers `qml/settings/pages/security.qml`, and it becomes
*more* useful after this work because it is how the CFI kernel, lockdown
state and enforcing AppArmor become visible. `triage.rs` (1,150 lines plus
811 lines of tests) gets the subcommand it never had in `main.rs` —
`nix/home/sandbox/triage.nix` and `apparmor-store.nix` both already reference
`dots-sandbox triage` as though it exists.

**Then delete** `policy.rs`, `argv.rs`, `launch.rs`, `broker.rs`,
`grants.rs`, `daemon.rs`, `catalog.rs` and their tests; `nix/home/sandbox/`
(`wrap.nix`, `machined.nix`, `daemon.nix`);
`nix/modules/system/sandbox-host.nix`; `nix/data/sandbox-policy.json`;
`tests/sandbox.nix` and `tests/sandbox-machined.nix` plus their
`tests/default.nix` entries and the `sandbox-policy-eval` check;
`qml/sandbox/`; and `mkSandboxedApp`/`isSandboxExempt` in `flake/apps.nix`.

`nix/home/ai/claude.nix:218` and `nix/home/ai/edupage-mcp.nix:225`
**destructure** `wrapSandboxed`, so they must change in the same commit or
evaluation fails. Per ruling R3 the eight flake apps then run unwrapped.

**Then close the gap that replaces the confinement:**

1. `services.flatpak.enable = true` at the system level. Today the module is
   user-installation-only, which `flatpaks.nix`'s header flags as a known
   one-line follow-up.
2. Port secureblue's global deny into `services.flatpak.overrides.global`,
   verbatim from the block quoted above, **keeping `host-os:ro`** (R5). The
   existing per-app grants at `flatpaks.nix:262+` layer on top.
3. AppArmor to **enforce** for the native holdouts with no Flathub package:
   `claude-desktop` and `haveno`. `kitty` stays deliberately unconfined — a
   terminal's job is spawning host commands. Profiles are derived by running
   `triage` over the existing complain-mode denial log, not hand-guessed, and
   the `9b069e8` incident in `hardening.nix:75-119` is the explicit
   cautionary precedent.
4. `security.qml` repointed: per-app capability toggles (meaningless without
   the policy model) become Flatpak permission state and AppArmor profile
   mode; the hardware/privacy dashboard half stays, against the extracted
   report crate.

### Phase D — finish Quickshell

Four additions, each a directory under
`nix/home/desktop/quickshell/qml/<feature>/` with pure logic in a
`pragma library` `.js` and a matching `tests/qml/tst_<feature>.qml`:

1. **`qml/idle/`** — the security one. No idle daemon exists anywhere in the
   repo, so the machine never auto-locks or blanks. Watch
   `ext-idle-notify-v1`, call `loginctl lock-session` (which
   `services.systemd-lock-handler`, `core.nix:14`, already routes to the
   existing `hyprlock.service` through `lock.target`), and
   `hyprctl dispatch dpms off`. Reuses the existing lock path; introduces no
   new authenticator.
2. **`qml/media/`** — `Quickshell.Services.Mpris` is simply never imported.
3. **Network write path** in `qml/bar/Network.qml` — it already reads
   `Quickshell.Networking`; add AP selection and passphrase entry so
   `nm-applet` can leave `nix/home/desktop/session/actions.nix:89`.
4. **Calendar popup** on `qml/bar/Clock.qml` — pure layout.

Bluetooth is dropped from this phase because Phase C removes Bluetooth.

**Not absorbed, deliberately:** `hyprlock` and `hyprpolkitagent` stay
separate processes. PAM and the polkit authentication-agent D-Bus contract
are privileged interfaces with no Quickshell binding; reimplementing either
inside the shell's QML/JS process would be a security regression, not a
consolidation.

### Phase A — the kernel

New `nix/modules/system/kernel.nix`, gated on a `dots.kernel.harden` option
added to `nix/modules/dots.nix`, imported from `flake/nixos.nix` beside
`hardening.nix`. `core.nix:13`'s `boot.kernelPackages` moves here. The gate
keeps the stock kernel one boolean away and keeps the LiveISO
(`nix/system/iso.nix`, which imports none of the hardening stack) out of a
from-source build.

Source is `fetchurl`-pinned from kernel.org. Config is the full "Measured
baseline" kernel set plus `LTO_CLANG_THIN=y`, `CFI_CLANG=y`,
`CFI_PERMISSIVE=n`, `LSM="lockdown,yama,integrity,apparmor,bpf,landlock"`,
and the surface removals (`LEGACY_TIOCSTI`, `DEVMEM`, `DEVPORT`,
`PROC_KCORE`, `BINFMT_MISC`, `X86_VSYSCALL_EMULATION`, `COMPAT_BRK`,
`MODIFY_LDT_SYSCALL` all off). Built with
`stdenv = pkgs.llvmPackages.stdenv` so the kernel's own build uses `LLVM=1`.

Per ruling R4, this phase also creates the **persistent module signing key**:
nixpkgs mints an ephemeral key per kernel build and discards it, which can
never sign the out-of-tree module Phase A2 needs. Generate a real keypair,
hold it in `secrets/` through agenix (already a flake input, currently used
for exactly one secret), and point `CONFIG_MODULE_SIG_KEY` at it.

Per R1 and R2 this phase also lands `module.sig_enforce=1` and
`lockdown=confidentiality`. `lockdown=confidentiality` costs nothing here:
it blocks hibernation, and `disko.nix:105`'s `randomEncryption` swap already
makes hibernation impossible.

**Same commit fixes the safety net**, which is not optional given a
from-source kernel with no cache and CFI going straight to enforcing:
`maintenance.nix` to `--delete-older-than 30d`, `boot.nix:34`
`maxGenerations` to 5, and the kernel version bump moves off the daily
`nix flake update` onto its own deliberate schedule.

### Phase A2 — CFI and ThinLTO for the open NVIDIA modules

An out-of-tree module loaded into a kCFI kernel must be built with matching
flags or it traps on the first indirect call. `open-gpu-kernel-modules` is
real source rather than the old `nv-kernel.o_binary` blob, so this is
possible.

Override the nvidia-open package with `stdenv = pkgs.llvmPackages.stdenv`
and `makeFlags = [ "LLVM=1" ]`. The kernel's own `KBUILD_CFLAGS` already
propagate `-fsanitize=kcfi` and `-flto=thin` into external module builds
against its build tree, so the work is making the driver compile under
clang, not re-deriving flags. Signing uses the key Phase A created.

## Rulings carried from the pre-flight scan

R1, R2, R3, R4, R5, R6 as recorded in the SDD ledger at
`.superpowers/sdd/snug-herding-cupcake/progress.md`. In summary: two kargs
move from Phase C to Phase A because they depend on kernel config Phase A
supplies; the eight flake apps run unwrapped after Phase E; the module
signing key is built in Phase A rather than retrofitted in A2; the Flatpak
global deny keeps `host-os:ro`; and Phase B's per-service hardening copies
`searxng.nix`'s proven directive set.

## Verification contract

Nix work runs through the toolbox container (`podman start nix`); `nix` on
the development host is a shell function wrapping `nix-toolbox`, not a bare
binary.

| Phase | Gate |
|---|---|
| All after 0 | `nix build .#checks.x86_64-linux.session-boot` — the session must still start |
| All | `nix run .#nix-lint` — flake eval, fmt/clippy/test, `qmllint --max-warnings 0`, `qmltestrunner` |
| C | `nix eval …config.boot.kernelParams` and `…boot.kernel.sysctl`, diffed against the measured baseline; confirm removed services are absent from the closure, not merely unreferenced |
| B | `systemd-analyze security` against secureblue's scores; `grep hardened /proc/self/maps` in a spawned process |
| E | New `tests/flatpak.nix`: the global deny holds, a per-app grant re-opens it, and `aa-status` reports `claude-desktop`/`haveno` **enforcing** with a nonzero confined-process count. `report.rs` and `triage.rs` test suites still pass after extraction |
| D | `tst_idle.qml` for the idle state machine, offscreen; plus manual confirmation the session actually locks on timeout |
| A | Build the kernel; assert `CONFIG_CFI_CLANG=y` and `CONFIG_LTO_CLANG_THIN=y` in the **realised** `.config` (a silently dropped option is the likeliest failure); `nix run .#nix-smoke`; then `nixos-rebuild boot` (never `switch`) with a known-good generation present, and `dmesg \| grep -i cfi` after a working session |
| A2 | Build with `hasNvidia` forced true; `modinfo nvidia` shows a signature; boot the tower and watch for `CFI failure` under GPU load |

## Out of scope

Secure Boot and UKI signing stay removed (`nix/README.md:143-166`). Without
them, `lockdown=confidentiality` and CFI protect a kernel whose image is not
itself verified at boot. Worth stating plainly rather than implying this
project closes that gap; revisiting it is its own spec.

## Open risks

**Codeberg cannot host a binary cache.** Forgejo's generic package registry
forbids `/` in filenames, so the `nar/<hash>.nar.xz` path Nix requires cannot
be represented — this is upstream issue
[forgejo#6872](https://codeberg.org/forgejo/forgejo/issues/6872), filed by
someone attempting exactly this, still open. Actions artifacts are
zip-wrapped. Codeberg Pages is git-backed with a ~100 MiB guidance for
personal repos, and their storage policy explicitly names "abused as a
content delivery network" as the pattern being fought, so a personal NAR
store there would be a real misuse of a donation-funded non-profit. Their
shared runners cap at 4 cores / 8 GB / **10 minutes**. Builds are therefore
local, and a bad mainline release costs an evening with no substitute to fall
back on. Optional future fix, unverified and out of scope: register the
`matthiaspc` tower as a self-hosted runner and add `ssh-ng://matthiaspc` as a
substituter.

**The Rust salvage is a refactor inside a deletion project.** Extracting
`report.rs` and wiring `triage.rs` is ~2,150 lines of work riding along in a
phase whose headline is removal. It can grow past its estimate.

**Phase A2 cannot be validated on the development machine.** That laptop is
AMD-only (Barcelo iGPU); the NVIDIA work builds blind and only proves out on
the tower. NVIDIA's driver leans heavily on function-pointer tables, which is
exactly what kCFI checks, so "compiles under clang" does not imply "survives
CFI". If it traps, the fallback is `CFI_PERMISSIVE` on that host alone.
