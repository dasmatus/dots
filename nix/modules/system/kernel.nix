# Phase A of the hardening design
# (docs/superpowers/specs/2026-09-08-hardening-design.md): a from-source,
# Clang-built, CFI-enforcing, ThinLTO kernel on a config baseline measured
# off a live secureblue host. Gated on dots.kernel.harden
# (nix/modules/dots.nix), default on for tokyonight — this is the only phase
# of the project that can make the machine fail to BOOT, so the stock kernel
# stays one boolean away, AND a `stock-kernel` specialisation below stays
# reachable from the Limine menu without a working system at all (R41 — see
# that section for why the boolean alone is not enough). The LiveISO
# (nix/system/iso.nix) imports none of this: it builds its own module list
# and never pulls in tokyonightModules, so `nix run .#iso` never triggers a
# from-source kernel build.
#
# `nix/modules/system/core.nix:13`'s `boot.kernelPackages = pkgs.linuxPackages_latest;`
# used to be the only kernel declaration in the tree. It lives here now,
# switched on dots.kernel.harden.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.kernel;
  inherit (lib.kernel) yes no option freeform;

  # -- The stdenv (R37 / research-llvm-kernel.md §1) --------------------
  #
  # `stdenv = pkgs.llvmPackages.stdenv` alone is NOT an LLVM=1-equivalent
  # toolchain on this pkgs set: it is Clang-as-CC plus stock GNU binutils
  # (`llvmPackages.stdenv.cc.bintools.bintools` resolves to GNU binutils —
  # NixOS/nixpkgs#277564, open, unresolved). Proven the hard way: with the
  # bare stdenv, `LTO_CLANG_THIN`'s own Kconfig gate
  # (`HAS_LTO_CLANG depends on CC_IS_CLANG && LD_IS_LLD && AS_IS_LLVM`)
  # never becomes true, so the option is never even prompted and silently
  # vanishes from the realised config — a "CFI_CLANG"-shaped trap (see
  # below) but for the linker instead of a renamed Kconfig symbol.
  # Assembling the stdenv by hand with `llvmPackages.bintools` is what
  # actually makes `LD_IS_LLD`/`AS_IS_LLVM` true; nixpkgs' own
  # common-flags.nix then points `CC=`/`LD=`/`AR=`/... at the now-real LLVM
  # unwrapped binaries, which is functionally `LLVM=1` even though nixpkgs
  # never literally passes that make variable.
  llvmStdenv = pkgs.overrideCC pkgs.llvmPackages.stdenv (
    pkgs.llvmPackages.stdenv.cc.override { bintools = pkgs.llvmPackages.bintools; }
  );

  # -- The source pin (R39 / research-mainline-pin.md) -------------------
  #
  # `pkgs.linuxPackages_latest` on this flake's nixpkgs pin resolves to
  # `linux_7_1` = 7.1.8, and the entire 7.1 series went EOL on 2026-09-02 —
  # a full major series behind kernel.org's current stable, on a branch that
  # will never receive another patch. 7.2.4 is kernel.org's current stable
  # at time of writing: not a same-day .0 (three weeks and four patch
  # releases into the 7.2 series) and not the in-development 7.3-rc tree,
  # which this design's own "no binary cache, local builds only" risk
  # profile rules out on its own.
  #
  # Anchored on the concrete `linux_7_1` branch attribute rather than the
  # rolling `linux_latest`/`linuxPackages_latest` alias, deliberately:
  # `linux_7_1`'s own entry in linux-kernels.nix is what selects which
  # kernelPatches apply (two evergreen, version-agnostic ones — see below),
  # and that selection needs to stay fixed under this override rather than
  # silently changing to whatever nixpkgs promotes to "latest" on the next
  # `nix flake update`. This also delivers the brief's other requirement for
  # free: `nix flake update` only ever rewrites flake.lock's *flake inputs*
  # (nixpkgs, home-manager, etc.); a `fetchurl` literal here is invisible to
  # it by construction, so a mainline release never lands on this machine
  # unattended — moving the version forward is a human editing this file.
  # One residual, worth stating plainly: pinning the *source* does not pin
  # the *compiler* — llvmStdenv above still rides nixpkgs' own `nixpkgs.
  # llvmPackages`, so the exact bytes this kernel compiles to can still
  # shift on a daily `nixos-rebuild boot` even though the kernel *version*
  # cannot.
  #
  # Hash verified two independent ways: a real `nix store prefetch-file`
  # against the tarball, and kernel.org's own PGP-signed
  # `v7.x/sha256sums.asc` (hex-to-base64 matched byte for byte). Re-verify
  # before trusting this line if it's ever bumped by hand.
  kernelVersion = "7.2.4";
  kernelSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${kernelVersion}.tar.xz";
    hash = "sha256-AXEO4Bc32sSS8brlK+zQV+CNINEViQiaoGrM/0FcKN0=";
  };

  # -- The override (R36/R37/R39, research-llvm-kernel.md) ----------------
  #
  # `linuxKernel.kernels.linux_7_1` is not generic.nix's own makeOverridable
  # result directly — it is `mainline.nix`'s. Read directly (pkgs/os-specific
  # /linux/kernel/mainline.nix on this flake's nixpkgs pin): mainline.nix
  # computes ITS OWN `version`/`src` from `branch` via kernels-org.json and
  # then builds `args' = (removeAttrs args ["branch"]) // { inherit src
  # version; ...  } // (args.argsOverride or {});` before calling
  # `buildLinux args'`. That middle `//` block OVERWRITES a plain
  # `version`/`src` passed to `.override` unconditionally — proven by
  # building this exact override without `argsOverride` and watching the
  # configfile unpack nixpkgs' own `linux-7.1.8.tar.xz` regardless of what
  # was requested here. `argsOverride` is mainline.nix's own, deliberate
  # escape hatch for exactly this: it is merged in LAST, so it is the only
  # way to actually replace the version/src a `linux_X_Y` branch attribute
  # hardcodes. `stdenv` and `structuredExtraConfig` do not need this
  # treatment — mainline.nix's own merge never touches either key, so a
  # plain top-level override of those two reaches generic.nix unmolested
  # (confirmed the same way: the realised config showed CFI/LTO_CLANG_THIN
  # correctly gated on a real Clang+lld toolchain on the very same build
  # that still had the wrong kernel version).
  hardenedKernel = pkgs.linuxKernel.kernels.linux_7_1.override {
    stdenv = llvmStdenv;
    argsOverride = {
      version = kernelVersion;
      src = kernelSrc;
      modDirVersion = lib.versions.pad 3 kernelVersion;

      # `LLVM=1` literally, not just an LLVM-shaped stdenv.
      #
      # The `llvmStdenv` above is what satisfies the Kconfig gates
      # (CC_IS_CLANG, LD_IS_LLD, AS_IS_LLVM), and the realised config proves
      # it: clang 21.1.8, all three `=y`. But nixpkgs' common-flags.nix sets
      # only the build-side tool variables it knows about. `LLVM=1` is the
      # kernel's own switch and additionally redirects HOSTCC, HOSTCXX,
      # HOSTLD, HOSTAR, NM, OBJCOPY, OBJDUMP, READELF and STRIP. Host tools
      # being GCC-built weakens nothing in the shipped image, but it is a
      # divergence between "functionally LLVM=1" and LLVM=1, and closing it
      # costs one list entry.
      #
      # It matters most for what this kernel EXPORTS rather than what it
      # builds. Out-of-tree modules (nix/system/hosts.nix's nvidia-open,
      # Phase A2) compile against the dev output's build tree and inherit the
      # toolchain recorded there. A build tree that half-remembers its
      # toolchain is how a module ends up compiled without matching kCFI and
      # traps on its first indirect call — a black screen rather than a build
      # error, on hardware that is not in front of anyone.
      #
      # `extraMakeFlags` rather than an `overrideAttrs` on `makeFlags`
      # because it is the supported seam, and it is the only one that
      # reaches every consumer that matters (read directly off this exact
      # nixpkgs pin, not assumed):
      #   - generic.nix:50 declares the parameter; :166/:195 thread it into
      #     `configfile`'s own `makeFlags` (via common-flags.nix), so even
      #     the Kconfig-resolution pass runs under LLVM=1;
      #   - generic.nix:294 hands it to `build.nix`'s kernel derivation,
      #     whose own `extraMakeFlags ? []` (build.nix:56) reaches the real
      #     build TWICE — folded into `commonMakeFlags` via common-flags.nix
      #     (build.nix:122-128, then `++ commonMakeFlags` at :290 for the
      #     make invocation itself) and appended a second time straight
      #     onto `buildFlags` at :227 (the `vmlinux modules ...` target
      #     list);
      #   - build.nix:505-515 exposes both `stdenv` and `commonMakeFlags` on
      #     the kernel derivation's own passthru, which is what
      #     `packagesFor` (pkgs/top-level/linux-kernels.nix) reads to build
      #     `kernelModuleMakeFlags` for every out-of-tree module — the
      #     nvidia-open build below inherits `LLVM=1` through that exact
      #     path, not by copying the flag onto its own derivation.
      # An `overrideAttrs` on the finished kernel derivation would only
      # have reached the second of these three, missing `configfile` and
      # every out-of-tree consumer of `commonMakeFlags`.
      #
      # `LLVM_IAS` deliberately absent: Documentation/kbuild/llvm.rst
      # documents it as a disable switch (`LLVM_IAS=0` falls back to the
      # non-integrated GNU assembler), not a second enable flag — its
      # unset default already means "use Clang's integrated assembler",
      # which `CONFIG_AS_IS_LLVM=y` in the realised config already shows is
      # in effect. Setting `LLVM_IAS=1` would be a no-op with this
      # toolchain, not a stricter one.
      extraMakeFlags = [ "LLVM=1" ];
    };

    structuredExtraConfig = {
      # -- Phase A additions: the layer secureblue's GCC-built,
      # CONFIG_LTO_NONE kernel cannot have, plus the surface removals the
      # design spec pairs with them.
      LTO_CLANG_THIN = yes;
      # NOT `CFI_CLANG`. On this kernel line CFI_CLANG is Kconfig
      # `transitional`: no prompt, its value is read once as CFI's own
      # `default`, and it is never written into a new .config. Requesting
      # `CFI_CLANG = yes;` produces a realised config with no
      # CONFIG_CFI_CLANG line at all — "unused option: CFI_CLANG", a hard
      # `configfile` build failure on x86_64 (ignoreConfigErrors defaults to
      # false there) rather than a silent drop. `CFI` is the live symbol.
      # FINEIBT/FINEIBT_BHI/CFI_AUTO_DEFAULT then appear in the realised
      # config on their own once IBT + retpoline are already satisfied by
      # the x86_64 arch defaults — that is FineIBT layering hardware
      # assistance on top of the same mechanism, expected and welcome, not
      # a conflict to "fix".
      CFI = yes;
      CFI_PERMISSIVE = no;
      # Diverges from secureblue's "selinux,...,ipe" — NixOS has no SELinux
      # or IPE. Task 5 (AppArmor enforcing) depends on "apparmor" being in
      # this exact string.
      LSM = freeform "lockdown,yama,integrity,apparmor,bpf,landlock";

      LEGACY_TIOCSTI = no;
      DEVMEM = no;
      DEVPORT = no;
      PROC_KCORE = no;
      # common-config.nix sets this mandatory `yes`; mkForce to flip it.
      BINFMT_MISC = lib.mkForce no;
      X86_VSYSCALL_EMULATION = no;
      COMPAT_BRK = no;
      MODIFY_LDT_SYSCALL = no;
      # Explicitly NOT set: IA32_EMULATION=n. Steam's runtime is 32-bit
      # (ruling R11) — this repo enables Steam (nix/modules/desktop/steam.nix).

      # Kconfig fallout of DEVMEM=no: common-config.nix makes both of these
      # mandatory `yes` and both `depends on DEVMEM`, so their own prompts
      # vanish the moment DEVMEM is off — softened to a warning instead of
      # the same "unused option" hard failure DEVMEM=no would otherwise
      # cause transitively.
      STRICT_DEVMEM = lib.mkForce (option no);
      IO_STRICT_DEVMEM = lib.mkForce (option no);
      # Kconfig fallout of the Clang/LLVM stdenv: switching CC breaks
      # Rust-for-Linux's own Kconfig availability probe, unrelated to
      # CFI/LTO and not this task's bug to fix. This repo builds no
      # Rust-for-Linux driver, so softened rather than chased.
      RUST = lib.mkForce (option no);
      DRM_NOVA = lib.mkForce (option no);
      NOVA_CORE = lib.mkForce (option no);
      DRM_PANIC_SCREEN_QR_CODE = lib.mkForce (option no);

      # -- Measured baseline (design spec, "Measured baseline: what
      # secureblue actually does") — the config half of what a GCC-built,
      # non-LTO, non-CFI kernel can still carry, and which tokyonight must
      # match regardless of the Clang/CFI layer on top.
      INIT_ON_ALLOC_DEFAULT_ON = yes;
      INIT_STACK_ALL_ZERO = yes;
      HARDENED_USERCOPY = yes;
      HARDENED_USERCOPY_DEFAULT_ON = yes;
      BUG_ON_DATA_CORRUPTION = yes;
      SCHED_STACK_END_CHECK = yes;
      SLAB_FREELIST_RANDOM = yes;
      SLAB_FREELIST_HARDENED = yes;
      SHUFFLE_PAGE_ALLOCATOR = yes;
      RANDOMIZE_BASE = yes;
      RANDOMIZE_MEMORY = yes;
      RANDOMIZE_KSTACK_OFFSET_DEFAULT = yes;
      STRICT_KERNEL_RWX = yes;
      STRICT_MODULE_RWX = yes;
      DEBUG_WX = yes;
      SECURITY_DMESG_RESTRICT = yes;
      DEBUG_LIST = yes;
      # common-config.nix sets both of these mandatory `no` (r13y comment:
      # "generates a random key during build and bakes it in"). Kept ON
      # here for PROVENANCE ONLY — see the module-signing decision below —
      # not for enforcement: no `module.sig_enforce=1` karg is added.
      MODULE_SIG = lib.mkForce yes;
      MODULE_SIG_ALL = yes;
      MODULE_SIG_SHA512 = yes;
      SECURITY_LOCKDOWN_LSM = lib.mkForce yes;
      SECURITY_LOCKDOWN_LSM_EARLY = yes;
      COMPAT_VDSO = no;
      BPF_UNPRIV_DEFAULT_OFF = yes;

      # Two things secureblue's GCC/non-LTO kernel does NOT set, which
      # tokyonight does (design spec, same section).
      ZERO_CALL_USED_REGS = yes;
      STATIC_USERMODEHELPER = yes;
      # INIT_ON_FREE_DEFAULT_ON is deliberately absent: secureblue forces it
      # by karg (init_on_free=1, hardening.nix already carries it) rather
      # than at compile time, and tokyonight already carries that same
      # karg — setting the _DEFAULT_ON config on top would be redundant,
      # not a gap.

      # NOTE: RANDOM_KMALLOC_CACHES is deliberately absent, not forgotten.
      # It is the SAME transitional-symbol trap as CFI_CLANG above, just for
      # a different feature: common-config.nix itself only sets it
      # `whenBetween "6.6" "7.2" yes` and renames it to
      # `KMALLOC_PARTITION_CACHES`/`KMALLOC_PARTITION_RANDOM` (both
      # `whenAtLeast "7.2" yes`) starting exactly at kernel 7.2 — confirmed
      # by reading common-config.nix directly, not guessed. On this
      # kernel's 7.2.4 pin those two successor symbols are already
      # mandatory `yes` from nixpkgs' own base config; requesting the old
      # name here would have hard-failed the `configfile` build exactly
      # like CFI_CLANG did.
    };
  };

  hardenedKernelPackages = pkgs.linuxPackagesFor hardenedKernel;
in
{
  # Lazy by construction: when dots.kernel.harden is false, nothing above
  # forces `hardenedKernel`/`llvmStdenv`, so a machine with the gate off
  # never evaluates, let alone builds, any of it.
  boot.kernelPackages = if cfg.harden then hardenedKernelPackages else pkgs.linuxPackages_latest;

  # The two kernel args that depend on config only this task supplies
  # (rulings R1/R2, moved here from Phase C). `lockdown=confidentiality`
  # needs SECURITY_LOCKDOWN_LSM(+_EARLY) and "lockdown" in CONFIG_LSM, both
  # above; it costs nothing here — it blocks hibernation, and
  # nix/system/disko.nix's `randomEncryption` swap already makes
  # hibernation impossible. `module.sig_enforce=1` is NOT added — see the
  # module-signing decision below (R38).
  boot.kernelParams = lib.mkIf cfg.harden [ "lockdown=confidentiality" ];

  # -- The module-signing decision (R38, research-module-signing.md) ------
  #
  # The original ruling (hold the key in secrets/ via agenix, point
  # CONFIG_MODULE_SIG_KEY at it) does not work: agenix decrypts at
  # ACTIVATION, never at evaluation or build time, and a kernel derivation
  # needs the key inside a build sandbox that cannot read host secrets. A
  # private key placed anywhere a Nix build CAN read it is world-readable in
  # the store, which defeats the point of signing.
  #
  # Investigated the "likely shape" (embed only the public certificate via
  # CONFIG_SYSTEM_TRUSTED_KEYS, sign the out-of-tree module separately) by
  # reading nixpkgs' own kernel `dev` output directly: there is no `certs/`
  # under `$dev/lib/modules/*/build` at all — nixpkgs' `build.nix` only ever
  # copies `.config` and `Module.symvers` out of the build sandbox, and a
  # fresh `modules_prepare` pass repopulates the rest from an
  # `--exclude=/build/` source copy. No private key of any kind survives
  # into a place an out-of-tree module build (Task 8's nvidia module
  # included) can reach it — confirmed against this exact nixpkgs pin, not
  # assumed. nixpkgs' own prior attempt at in-store signing
  # (NixOS/nixpkgs#87426) was never merged, for the reason its own author
  # gave: a kernel rebuilt twice regenerates the key and invalidates every
  # certificate already baked into already-signed modules. Real
  # distributions (Fedora's akmods, Debian's MOK+DKMS) solve this by
  # generating the key on the LIVE filesystem and signing post-build,
  # outside any reproducible package build entirely — describable as a
  # NixOS activation-time pipeline, but that is net-new infrastructure with
  # its own fragility class, out of scope for this task and not assumed
  # into Task 8 either.
  #
  # TAKING THE PRE-APPROVED FALLBACK, deliberately, not half-implemented:
  # MODULE_SIG/MODULE_SIG_ALL/MODULE_SIG_SHA512 stay ON above, matching
  # secureblue's measured baseline, for PROVENANCE only (`modinfo` shows a
  # signature, signed by this build's own ephemeral, discarded key). No
  # `module.sig_enforce=1` karg is added anywhere in this module. Cost:
  # unsigned modules can still be loaded by root — this loses
  # tamper-resistance against an already-root attacker while keeping
  # everything else CFI/ThinLTO/lockdown provide. That is a real loss, but a
  # much smaller one than shipping a machine that cannot load its own GPU
  # driver, or putting a signing key in the world-readable Nix store.

  # -- The stock-kernel fallback that does NOT need a working system -----
  # (R41, research-safety-net.md) --
  #
  # "One boolean away" (dots.kernel.harden) is necessary but not
  # sufficient: flipping it requires a machine that can already evaluate
  # and rebuild, which is exactly what a CFI trap on boot denies. A NixOS
  # specialisation adds a second, always-present Limine menu entry built
  # from THIS SAME generation with dots.kernel.harden forced off — so
  # recovering from a bad boot costs one keypress at the bootloader, not
  # rescue media or a second machine to rebuild from. It shares the
  # generation's own GC lifetime (nix.gc's 30d, maintenance.nix) rather than
  # depending on an older generation still being present, and it costs
  # little to build: the stock `linuxPackages_latest` it falls back to is
  # cache-substituted, not built from source, so `nixos-rebuild boot`
  # doesn't pay a second from-scratch kernel compile for it.
  #
  # ESP capacity is this mechanism's real constraint, not evaluation cost:
  # nix/system/disko.nix sizes the ESP at 2G, and Limine copies a
  # kernel+initrd pair per specialisation per generation onto it (confirmed
  # by reading limine-install.py's generate_config_entry/config_entry
  # directly — each specialisation entry carries its own independent
  # BootSpec, copied the same way the base "Default" entry is). Five
  # generations (boot.nix's maxGenerations) times two kernel+initrd sets
  # (hardened + stock-kernel) is meaningfully more ESP traffic than the two
  # generations x one kernel this machine ran before Phase A. See this
  # task's report for the measured per-generation size and whether 2G
  # holds; disko.nix's `esp.size` only affects a FUTURE install in any
  # case — it cannot resize an already-partitioned disk on the machine this
  # design targets.
  specialisation.stock-kernel.configuration = {
    dots.kernel.harden = false;
  };
}
