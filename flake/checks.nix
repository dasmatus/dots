# checks.${system} — the cheap eval-only checks (settings, facter stub/nvidia,
# FIDO 2FA PAM rules, aipage manifest) plus the dots-installer build gate.
# The LiveISO boot oracle lives in tests/default.nix and is merged in from
# flake.nix (it needs the ISO wiring).
{
  pkgs,
  system,
  ...
}:
self:
let
  lib = pkgs.lib;
  settings = (import ../nix/system/defaults.nix) // (import ../nix/data/settings.nix);
in
{
  dots-installer = self.packages.${system}.dots-installer;
  settings-eval = pkgs.writeText "settings-ok" (
    builtins.concatStringsSep "\n" [
      settings.username
      settings.hostname
      (builtins.concatStringsSep "," settings.disks)
      settings.swapSize
    ]
  );
  # The committed facter.json stub ({}) must leave every detection off,
  # including the nvidia if-then-else in nix/system/hosts.nix.
  facter-stub-eval =
    assert
      self.nixosConfigurations.tokyonight.config.services.xserver.videoDrivers == [
        "modesetting"
      ];
    pkgs.writeText "facter-stub-ok" "modesetting";
  # Phase A (docs/superpowers/specs/2026-09-08-hardening-design.md): assert
  # the REALISED kernel .config, not the requested structuredExtraConfig —
  # a dropped or silently-overridden option (an unmet Kconfig `depends on`,
  # a renamed symbol) is the likeliest failure mode for a from-source
  # kernel override, and it is invisible to a check that only reads back
  # the request. `kernel.configfile`'s own $out IS the realised .config
  # text file (`installPhase = "mv $buildRoot/.config $out";` in nixpkgs'
  # build.nix) — cheap to build (Kconfig resolution only, no compilation),
  # and exactly what the real kernel build consumes as its own .config.
  # `nix flake check --no-build` only evaluates this (no derivation is
  # forced), so it stays free on the everyday gate; `nix build
  # .#checks.x86_64-linux.kernel-config-realised` is what actually proves
  # it, and is Phase A's own verification step.
  kernel-config-realised =
    let
      cfgFile = self.nixosConfigurations.tokyonight.config.boot.kernelPackages.kernel.configfile;
    in
    pkgs.runCommand "kernel-config-realised" { } ''
      cfg=${cfgFile}
      grep -qE '^CONFIG_CC_IS_CLANG=y$' "$cfg" || { echo "not actually built with clang"; exit 1; }
      grep -qE '^CONFIG_LD_IS_LLD=y$' "$cfg" || { echo "not actually linked with lld"; exit 1; }
      grep -qE '^CONFIG_CFI=y$' "$cfg" || { echo "CFI not enabled (NOT CFI_CLANG -- that symbol is transitional on this kernel and never appears)"; exit 1; }
      grep -qE '^CONFIG_LTO_CLANG_THIN=y$' "$cfg" || { echo "ThinLTO not enabled"; exit 1; }
      if grep -q '^CONFIG_CFI_PERMISSIVE' "$cfg"; then echo "CFI_PERMISSIVE leaked in -- permissive mode is logging, not a mitigation"; exit 1; fi
      grep -qE '^CONFIG_LSM="[^"]*apparmor[^"]*"$' "$cfg" || { echo "apparmor missing from CONFIG_LSM -- Task 5's enforcing profiles would silently stop working"; exit 1; }
      if grep -q '^CONFIG_CFI_CLANG' "$cfg"; then echo "CONFIG_CFI_CLANG line present -- should never appear (transitional symbol)"; exit 1; fi
      touch $out
    '';

  # A synthetic report with an NVIDIA card (PCI vendor 0x10de = 4318) must
  # flip videoDrivers to nvidia, engage facter's CPU detection, and pass
  # every module assertion — asserting on config.assertions forces the
  # nvidia package eval, so a broken unfree allowlist fails here instead of
  # on the first on-machine rebuild. The cpu entry is mandatory: facter
  # asserts a non-empty hardware.cpu on baremetal.
  #
  # Task 8 / Phase A2 changed what "every module assertion" means here.
  # `dots.kernel.harden` defaults true, and this synthetic report makes
  # `hasNvidia` true, so nix/system/hosts.nix's own assertion — the one that
  # requires `dots.kernel.nvidiaCfiMatched` before letting the two combine —
  # is now IN this list on purpose. `nvidia-cfi-toolchain-eval` above proves
  # the wiring is correct; it does not and cannot prove the from-source
  # nvidia-open build actually succeeds against this exact kernel, because
  # that build has no binary cache and was not completed inside this
  # session's sandbox (no NVIDIA hardware to justify keeping it running
  # against a shared, memory-constrained host — see task-8-report.md). So
  # `nvidiaCfiMatched` correctly stays `false`, and the loud failure below is
  # the intended behaviour, not a regression: it is exactly the "eval error
  # instead of a black screen" the brief asked for. Once a future session
  # completes that build and flips the option, THIS check needs to flip
  # back to asserting `failed == []` — leaving it silently green today would
  # have hidden the exact gap Task 8 exists to be honest about.
  facter-nvidia-eval =
    let
      nvidiaSystem = self.nixosConfigurations.tokyonight.extendModules {
        modules = [
          {
            hardware.facter.report = {
              version = 2;
              system = "x86_64-linux";
              virtualisation = "none";
              hardware = {
                cpu = [ { vendor_name = "AuthenticAMD"; } ];
                graphics_card = [
                  {
                    vendor = {
                      hex = "10de";
                      value = 4318;
                    };
                  }
                ];
              };
            };
          }
        ];
      };
      inherit (nvidiaSystem) config;
      failed = map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
      cfiUnmatched = lib.strings.hasInfix "dots.kernel.nvidiaCfiMatched";
    in
    assert config.services.xserver.videoDrivers == [ "nvidia" ];
    assert config.hardware.nvidia.open;
    assert config.hardware.cpu.amd.updateMicrocode;
    assert builtins.elem "amd_pstate=active" config.boot.kernelParams;
    assert lib.assertMsg (builtins.length failed == 1 && cfiUnmatched (builtins.head failed))
      "expected exactly one failing assertion (the unverified nvidiaCfiMatched gate), got: ${builtins.toJSON failed}";
    pkgs.writeText "facter-nvidia-ok" "nvidia";
  # Task 8 / Phase A2: the assertion above only catches "nobody did the
  # CFI-matching work at all" (dots.kernel.nvidiaCfiMatched still false).
  # This one catches the narrower, sneakier failure — the flag got flipped
  # true but the actual override wiring silently stopped reaching the
  # nvidia-open derivation on some future nixpkgs bump. Eval-only: reading
  # `.makeFlags` off a derivation is a plain attrset lookup, not a build, so
  # this stays inside `nix flake check --no-build`'s budget the same way
  # `facter-nvidia-eval` above does.
  #
  # There is deliberately no override anywhere in this tree that sets
  # `hardware.nvidia.package` or re-derives nvidia-open's `stdenv` — reading
  # nixpkgs' own pkgs/top-level/linux-kernels.nix directly (this exact pin)
  # shows `packagesFor kernel_` already does that work: `self.callPackage =
  # newScope self` plus `inherit (kernel) stdenv;` ("in particular, use the
  # same compiler by default", that file's own comment) means
  # `config.boot.kernelPackages.nvidiaPackages` — and therefore
  # `hardware.nvidia.package`'s own default (`nvidiaPackages.${branch}`) —
  # is instantiated through the HARDENED kernel's scope, not nixpkgs' stock
  # one. nvidia-x11's own generic.nix never overrides `stdenv` or
  # `callPackage` when it builds its `mod`/`open` passthru via `callPackage
  # ./kernel-modules.nix {...}`, so that inheritance reaches kernel-modules.nix
  # unbroken, and `kernelModuleMakeFlags` (same file) is literally
  # `self.kernel.commonMakeFlags ++ [...]` — the hardened kernel's own
  # `extraMakeFlags = ["LLVM=1"]` (kernel.nix) is baked into
  # `commonMakeFlags` by common-flags.nix's trailing `++ extraMakeFlags`,
  # so it is already present on this list without this repo adding it a
  # second time. Asserting the three properties below is what would catch
  # that chain breaking: an unrelated stdenv (no clang in CC=), a stray
  # kernel (SYSOUT/SYSSRC pointing somewhere other than THIS build's own
  # `kernel.dev`), or the flag itself silently dropping.
  nvidia-cfi-toolchain-eval =
    let
      nvidiaSystem = self.nixosConfigurations.tokyonight.extendModules {
        modules = [
          {
            hardware.facter.report = {
              version = 2;
              system = "x86_64-linux";
              virtualisation = "none";
              hardware = {
                cpu = [ { vendor_name = "AuthenticAMD"; } ];
                graphics_card = [
                  {
                    vendor = {
                      hex = "10de";
                      value = 4318;
                    };
                  }
                ];
              };
            };
          }
        ];
      };
      inherit (nvidiaSystem) config;
      # `hasInfix`'s needle goes through `builtins.match` as part of the
      # regex it builds, and Nix refuses a regex built from a string that
      # still carries a store-path context ("is not allowed to refer to a
      # store path") — proven the hard way, not assumed. The context is
      # exactly what this assertion already established (both strings come
      # from evaluating THIS check's own `nvidiaSystem`), so discarding it
      # loses no safety, only the (here, redundant) build edge.
      hardenedDev = builtins.unsafeDiscardStringContext "${config.boot.kernelPackages.kernel.dev}";
      openDrv = config.hardware.nvidia.package.open;
      flags = builtins.concatStringsSep " " openDrv.makeFlags;
    in
    assert config.hardware.nvidia.open;
    # SYSOUT/SYSSRC (kernel-modules.nix) point at THIS build's own kernel.dev,
    # not some other kernel's, proving the headers/dev output actually used
    # is the hardened kernel's own rather than a stock or re-derived one.
    assert lib.strings.hasInfix hardenedDev flags;
    # CC= (common-flags.nix) resolved to the hardened kernel's llvmStdenv,
    # not a GCC default reached through some other path.
    assert lib.strings.hasInfix "clang" flags;
    # LLVM=1 flows in through commonMakeFlags (see kernel.nix's own comment
    # on the seam) rather than needing its own copy of the flag here.
    assert builtins.elem "LLVM=1" openDrv.makeFlags;
    pkgs.writeText "nvidia-cfi-toolchain-eval-ok" "matched";
  # Asserts the FIDO2 PAM rules under the default (requireKey=false): u2f
  # is `sufficient` (a correct key touch alone short-circuits the stack —
  # unlocks without the password), unix stays `sufficient` (password fallback),
  # and deny stays enabled (terminates failed auth). The dormant sudo service
  # is intentionally untouched. Catches a future nixpkgs bump that silently
  # changes the auto-rule controls/order. Eval-only (no build); reads the
  # already-evaluated tokyonight config (the default lives in the module).
  # The requireKey=true 2FA path is exercised by fido-2fa-strict-eval below.
  fido-2fa-eval =
    let
      cfg = self.nixosConfigurations.tokyonight.config;
      svc = cfg.security.pam.services;
      need = [
        "hyprlock"
        "ly"
        "login"
      ];
      sufficient =
        s:
        let
          r = svc.${s}.rules.auth;
        in
        r.u2f.control == "sufficient"
        && r.unix.control == "sufficient"
        && r.deny.enable
        && r.u2f.order < r.unix.order;
    in
    assert builtins.all sufficient need;
    assert cfg.security.pam.u2f.control == "sufficient";
    assert svc.sudo.rules.auth.unix.control == "sufficient";
    assert svc.sudo.rules.auth.deny.enable;
    pkgs.writeText "fido-2fa-ok" "u2f-sufficient";
  # Asserts the requireKey=true 2FA tightening (key AND password both
  # mandatory) when dots.fido.requireKey is flipped on — the recovery path
  # for users who want mandatory 2FA. u2f + unix both `required`, deny
  # disabled, u2f before unix. Uses extendModules so the default config
  # stays untouched for the check above.
  fido-2fa-strict-eval =
    let
      strict = self.nixosConfigurations.tokyonight.extendModules {
        modules = [
          { dots.fido.requireKey = true; }
        ];
      };
      cfg = strict.config;
      svc = cfg.security.pam.services;
      need = [
        "hyprlock"
        "ly"
        "login"
      ];
      twoFa =
        s:
        let
          r = svc.${s}.rules.auth;
        in
        r.u2f.control == "required"
        && r.unix.control == "required"
        && !r.deny.enable
        && r.u2f.order < r.unix.order;
    in
    assert builtins.all twoFa need;
    assert cfg.security.pam.u2f.control == "required";
    pkgs.writeText "fido-2fa-strict-ok" "required+required";
  # Asserts the in-flake aipage build (nix/packages/aipage.nix) evaluates, the
  # manifest is parseable at eval time (pure-eval readFile of a fetchGit store
  # path), the gecko addon id is stable, and both targets are MV2. Eval-only
  # — does not build the wasm (too slow for the lint gate); a full `nix build
  # .#aipage-firefox .#aipage-chrome` is the build gate.
  aipage-eval =
    let
      ff = self.packages.${system}.aipage-firefox;
      ch = self.packages.${system}.aipage-chrome;
      ffMan = ff.passthru.manifest;
      chMan = ch.passthru.manifest;
    in
    assert ffMan.browser_specific_settings.gecko.id == "edupage-ai-sidebar@hesburger.dev";
    assert ffMan.manifest_version == 2;
    assert chMan.manifest_version == 2;
    assert ff.passthru.aipageVersion == ffMan.version;
    pkgs.writeText "aipage-eval-ok" ff.passthru.aipageVersion;
  # nix/packages/aipage-bun.nix carries one fetchurl per JS dependency, and a
  # bun2nix regeneration once silently blanked two of them to `hash = ""`.
  # `fetchurl` accepts that and normalises it to the all-zero fixed-output
  # hash (`sha256-AAAA...=`), which only fails at realization time, after a
  # real network fetch, so neither eval nor a `.drvPath` force on
  # aipage-firefox/aipage-chrome (still a well-formed, if wrong, FOD) ever
  # sees it. Import the raw file with identity stand-ins for
  # fetchurl/fetchgit/fetchFromGitHub/copyPathToStore so every entry
  # evaluates to its own `{ url; hash; ... }` attrset instead of a real
  # derivation, then scan those for a blank hash directly — no store
  # interaction, no network, and it flags any blank entry in the file
  # rather than only the ones the two aipage packages currently happen to
  # reach. Also flag the literal all-zero hash string itself: it is what a
  # blank one normalises to at realization, so a future regeneration that
  # bakes that value in directly (rather than leaving it blank) would
  # otherwise fail exactly as late and as confusingly, unchecked by a
  # filter that only matches `hash == ""`.
  aipage-bun-hashes-eval =
    let
      raw = import ../nix/packages/aipage-bun.nix {
        copyPathToStore = x: x;
        fetchFromGitHub = args: args;
        fetchgit = args: args;
        fetchurl = args: args;
      };
      allZeroSha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      isBad =
        n:
        (raw.${n} ? hash)
        && (builtins.elem raw.${n}.hash [
          ""
          allZeroSha256
        ]);
      bad = builtins.filter isBad (builtins.attrNames raw);
    in
    assert lib.assertMsg (bad == [ ]) (
      "nix/packages/aipage-bun.nix has blank or all-zero hash entries: "
      + builtins.concatStringsSep ", " bad
    );
    pkgs.writeText "aipage-bun-hashes-eval-ok" "no-blank-hashes";
  # Form-factor detection (nix/modules/system/form-factor.nix) — assert the
  # committed facter.json stub ({}) leaves the auto-detection on the
  # "desktop" fallback (no report → no virtualisation, no form_factor),
  # and that synthetic reports steer CPU governor, thermald, PPD, lid
  # switch, sleep-target masking, swappiness, fstrim, and wifi powersave
  # onto the expected per-form-factor profile. Bluetooth is no longer part
  # of that per-form-factor matrix (Phase C,
  # docs/superpowers/specs/2026-09-08-hardening-design.md, removed it
  # outright — see the module-blacklist entries alongside it), so it is
  # asserted off unconditionally below rather than per form factor. Each
  # case extends the tokyonight config with a minimal facter report and
  # asserts the resolved config. Eval-only (no build).
  formfactor-eval =
    let
      # `dots.kernel.harden = false` on every variant below, including the
      # base. This check evaluates FOUR full tokyonight closures, and since
      # Phase A put nix/modules/system/kernel.nix into tokyonightModules,
      # each one of them otherwise carries a from-source, ThinLTO-linked
      # mainline kernel. That made a plain `nix flake check` try to pull the
      # kernel in four times over and OOM a 15G machine outright — killed at
      # this exact check, repeatedly, with SIGKILL.
      #
      # Nothing here is about the kernel. Every assertion below reads a
      # form-factor effect: governor, thermald, power-profiles-daemon, the
      # lid handler, sleep targets, fstrim, bluetooth. Those resolve
      # identically on a stock kernel, so paying for a kernel build to check
      # them is pure cost. The one place the hardened kernel IS built and
      # asserted is `kernel-config-realised`, which exists for exactly that
      # and evaluates one closure rather than four.
      #
      # Apply the same treatment to any future check that extends
      # `nixosConfigurations.tokyonight` and does not specifically care which
      # kernel is underneath.
      stockKernel = {
        dots.kernel.harden = false;
      };
      sys = self.nixosConfigurations.tokyonight.extendModules {
        modules = [ stockKernel ];
      };
      # cpu entry is mandatory on baremetal (facter asserts it); VMs skip it.
      bareCpu = [ { vendor_name = "AuthenticAMD"; } ];
      mkReport = report: {
        hardware.facter.report = report;
      };
      extend =
        report:
        sys.extendModules {
          modules = [
            (mkReport report)
            stockKernel
          ];
        };

      # Stub ({}) → desktop fallback.
      stub = sys.config;
      # Laptop via hardware.system.form_factor = "laptop".
      laptop = extend {
        version = 2;
        system = "x86_64-linux";
        virtualisation = "none";
        hardware = {
          cpu = bareCpu;
          system = {
            form_factor = "laptop";
          };
        };
      };
      # Server via a rack-mount chassis form_factor string.
      server = extend {
        version = 2;
        system = "x86_64-linux";
        virtualisation = "none";
        hardware = {
          cpu = bareCpu;
          system = {
            form_factor = "Rack Mount Chassis";
          };
        };
      };
      # VM via virtualisation = "kvm" (overrides any form_factor).
      vm = extend {
        version = 2;
        system = "x86_64-linux";
        virtualisation = "kvm";
        hardware = { }; # VMs don't expose a system form_factor.
      };
    in
    assert stub.dots.formFactor == "auto"; # unresolved option stays "auto"
    # The resolved class (read via the module's local binding through the
    # effect options) lands the desktop profile: performance governor,
    # thermald ON, PPD OFF, lid ignored, sleep targets masked.
    assert stub.powerManagement.cpuFreqGovernor == "performance";
    assert stub.services.thermald.enable;
    assert !stub.services.power-profiles-daemon.enable;
    assert stub.services.logind.settings.Login.HandleLidSwitch == "ignore";
    assert !stub.systemd.targets.sleep.enable;
    assert stub.services.fstrim.enable;
    # Bluetooth is off everywhere now, not just on server/VM — see the
    # comment above this check.
    assert !stub.hardware.bluetooth.enable;
    # laptop
    assert laptop.config.powerManagement.cpuFreqGovernor == "powersave";
    assert laptop.config.services.thermald.enable;
    assert laptop.config.services.power-profiles-daemon.enable;
    assert laptop.config.services.logind.settings.Login.HandleLidSwitch == "suspend";
    assert laptop.config.systemd.targets.sleep.enable;
    assert laptop.config.networking.networkmanager.wifi.powersave;
    assert laptop.config.boot.kernel.sysctl."vm.swappiness" == 60;
    assert !laptop.config.hardware.bluetooth.enable;
    # server
    assert server.config.powerManagement.cpuFreqGovernor == "performance";
    assert !server.config.services.thermald.enable;
    assert !server.config.hardware.bluetooth.enable;
    assert !server.config.systemd.targets.sleep.enable;
    assert server.config.boot.kernel.sysctl."vm.swappiness" == 20;
    # vm
    assert vm.config.powerManagement.cpuFreqGovernor == "schedutil";
    assert !vm.config.services.thermald.enable;
    assert !vm.config.services.fstrim.enable;
    assert !vm.config.hardware.bluetooth.enable;
    assert vm.config.boot.kernel.sysctl."vm.swappiness" == 10;
    # EPP tmpfiles rule carries the right string per profile.
    assert builtins.any (
      r: lib.strings.hasInfix "energy_performance_preference" r && lib.strings.hasSuffix " performance" r
    ) stub.systemd.tmpfiles.rules;
    assert builtins.any (
      r:
      lib.strings.hasInfix "energy_performance_preference" r
      && lib.strings.hasSuffix " balance_performance" r
    ) laptop.config.systemd.tmpfiles.rules;
    pkgs.writeText "formfactor-eval-ok" "desktop+laptop+server+vm";

  # nix/data/palette.json is the single source of truth for the system palette
  # (see docs/superpowers/specs/2026-08-23-system-palette-single-source-design.md).
  #
  # It used to be asserted against two Rust store srcs as well, because both
  # beamenu crates compiled it in through include_str! and that only resolved
  # when the src fileset was rooted at rust/ rather than at the crate directory.
  # The shell reads it at build time through builtins.fromJSON instead, so the
  # check worth having now is that the generated Theme.qml actually carries the
  # values: a typo in tree.nix would otherwise surface as a shell painted in
  # QML's default colours, which is a bad way to find out.
  palette-eval =
    let
      palette = builtins.fromJSON (builtins.readFile ../nix/data/palette.json);
      theme = builtins.readFile "${self.packages.${system}.quickshell-config}/Theme.qml";
      carries = value: builtins.match ".*${value}.*" theme != null;
    in
    assert palette.colors.bg == "#1a1b26";
    assert palette.colors.bgDarker == "#15161e";
    assert palette.accentFallback == "#7aa2f7";
    assert palette.alpha.panel == "f2";
    assert palette.alpha.heading == "ee";
    assert palette.alpha.opaque == "ff";
    assert palette.fonts.canvasUi == "Manrope";
    assert palette.beamenu.lines == 9;
    assert palette.bar.pillSpacing == 6;
    assert palette.settings.sidebarWidth == 260;
    assert palette.settings.panelWidthFactor == 0.72;
    assert carries palette.colors.bg;
    assert carries palette.accentFallback;
    assert carries palette.fonts.ui;
    pkgs.writeText "palette-eval-ok" palette.accentFallback;

  # The standalone home-manager build (flake/home.nix), forced to EVALUATE but
  # not to build. `.drvPath` is the whole trick: it demands that every module
  # in nix/home/profiles/portable.nix type-checks, that every option assignment
  # resolves, and that each specialArg the profile destructures
  # (`dots`, `settings`, the in-flake packages) is actually
  # supplied — while stopping short of realising a closure of browsers, editors
  # and a Haskell toolchain, which is not something `nix flake check` should
  # ever pull.
  #
  # This gate exists because the standalone build has no other backstop. The
  # NixOS side is covered transitively: nixosConfigurations.tokyonight forces
  # the same home modules through several checks below. flake/home.nix
  # reconstructs `pkgs`, the unfree predicate and the `dots` bridge by hand
  # (see its header for why each one cannot be borrowed), and NOTHING else in
  # this repo evaluates that reconstruction. Without this check its first
  # consumer would be a `home-manager switch` on a foreign host — the worst
  # place to discover a missing specialArg, since a failed activation there
  # leaves a half-applied generation on a machine this repo does not otherwise
  # manage.
  #
  # Keyed on the bare username rather than "user@host": flake/home.nix exposes
  # both, but that alias is the one whose resolution does not depend on what
  # the checking machine happens to be called.
  home-standalone-eval =
    let
      hm = self.homeConfigurations.${settings.username};
    in
    # unsafeDiscardStringContext is load-bearing, not a lint silencer. A bare
    # `.drvPath` carries a DrvDeep string context, and interpolating that into
    # a file makes the check depend on the derivation AND its whole input
    # closure being realised — i.e. `nix flake check` would build every
    # package the profile installs, which is the opposite of what this gate is
    # for. Dropping the context keeps the value (computing a drvPath at all
    # requires the full module evaluation this check wants) while leaving the
    # result a plain string.
    pkgs.writeText "home-standalone-ok" (
      builtins.unsafeDiscardStringContext hm.activationPackage.drvPath
    );

  hm-activation-eval =
    let
      sys = self.nixosConfigurations.tokyonight.config;
      hm = sys.home-manager.users.${sys.dots.username};

      deliberate = [ "checkLinkTargets" ];

      # A comment naming exit is not a call to it, and the one in
      # nix/home/ai/claude-desktop.nix explaining this rule is exactly that.
      isComment = line: builtins.match "[[:space:]]*#.*" line != null;

      # `exit` as a word: opening the line or following a shell operator, and
      # not the prefix of $exitCode, exited or exit_helper.
      callsExit =
        line:
        builtins.match "([[:space:]]*|.*[^[:alnum:]_$])exit([[:space:]]+[0-9]+)?[[:space:]]*" line != null;

      aborting =
        entry: builtins.any (line: !(isComment line) && callsExit line) (lib.splitString "\n" entry.data);

      offenders = builtins.attrNames (
        lib.filterAttrs (name: entry: !(builtins.elem name deliberate) && aborting entry) hm.home.activation
      );
    in
    # Named rather than counted, because the whole failure mode is not knowing
    # which entry swallowed the rest of the run.
    assert lib.assertMsg (offenders == [ ]) (
      "home.activation entries call exit, which ends the activation script "
      + "before linkGeneration: "
      + builtins.concatStringsSep ", " offenders
    );
    # The step the exit was skipping and the file it never linked, both named
    # so a rename cannot quietly turn this check into a no-op.
    assert hm.home.activation ? linkGeneration;
    assert hm.xdg.configFile ? quickshell;
    assert hm.xdg.configFile.quickshell.target == ".config/quickshell";
    pkgs.writeText "hm-activation-eval-ok" (
      builtins.concatStringsSep "\n" (builtins.attrNames hm.home.activation)
    );

  # How the shell gets started, which is not the same question as whether its
  # config is on disk. `hyprland.start` fires once at compositor boot, so a
  # shell launched only from that hook cannot come back on a rebuild — the QML
  # lands in ~/.config and nothing reads it until the next login. Every other
  # session-scoped thing here is a systemd user unit and does return: hyprmon
  # restarted during the very activation that first linked this shell, in the
  # same session, while the shell itself sat on disk unread.
  #
  # Both halves of the unit are the contract. Wanted by graphical-session
  # .target is what starts it at login. X-Restart-Triggers naming the config
  # tree is what makes sd-switch restart it when the QML changes rather than
  # only when the quickshell package does — without it the unit text is stable
  # across every edit to the shell and the bug returns wearing a systemd hat.
  #
  # And the hook must not launch it too, or a login races two shells onto one
  # IPC socket. The keybinds still speak `qs ipc call`, which is a client
  # talking to whatever instance is up, so those stay.
  shell-service-eval =
    let
      sys = self.nixosConfigurations.tokyonight.config;
      hm = sys.home-manager.users.${sys.dots.username};
      unit = hm.systemd.user.services.quickshell;
      lua = hm.xdg.configFile."hypr/hyprland.lua".text;
      # home-manager normalises ExecStart to a list; toString handles both.
      execStart = toString unit.Service.ExecStart;
    in
    assert hm.systemd.user.services ? quickshell;
    assert builtins.elem "graphical-session.target" unit.Install.WantedBy;
    assert builtins.elem "graphical-session.target" unit.Unit.PartOf;
    # The want symlink rather than just the unit: that is the half which
    # actually pulls the shell in at login, and it is generated from Install
    # rather than written out, so it is worth reading back.
    assert hm.xdg.configFile ? "systemd/user/graphical-session.target.wants/quickshell.service";
    # Keyed to the same tree the module links into ~/.config, so the two
    # cannot drift into a unit that restarts on a config it does not serve.
    assert builtins.elem "${hm.xdg.configFile.quickshell.source}" unit.Unit."X-Restart-Triggers";
    assert lib.hasInfix "quickshell" execStart;
    # Bare, because --path would key the instance to the store tree and strand
    # every `qs ipc call` client looking under ~/.config.
    assert !(lib.hasInfix "--path" execStart);
    # Started by the unit, not by the compositor.
    assert !(lib.hasInfix ''hl.exec_cmd("qs")'' lua);
    # But still reachable from the keybinds, which is a different code path
    # and must not be collateral damage of removing the start line.
    #
    # This is asserted in TWO halves because the keybind stopped calling `qs`
    # directly: nix/home/desktop/session generates a `dots-<action>@` template
    # unit per action, and the Hyprland bind starts that unit rather than
    # running the command itself. So the lua carries a `systemctl --user start
    # dots-launcher-toggle@…` line, and the ipc call lives one hop away in the
    # unit's own ExecStart.
    #
    # The single `hasInfix … lua` this replaces was written against the older
    # arrangement and had been false ever since — nothing caught it because
    # `nix flake check` could not evaluate this flake at all while
    # nix/data/settings.nix was a symlink into /var/lib/dots. Checking only the
    # lua again would re-freeze the assertion against today's indirection;
    # checking both ends keeps the original property ("the keybind still
    # reaches the launcher") true across either shape.
    assert lib.hasInfix "dots-launcher-toggle@" lua;
    assert lib.hasInfix "qs ipc call launcher toggle" (
      toString hm.systemd.user.services."dots-launcher-toggle@".Service.ExecStart
    );
    pkgs.writeText "shell-service-eval-ok" execStart;
}
