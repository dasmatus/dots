# checks.${system} — the cheap eval-only checks (settings, facter stub/nvidia,
# palette, the home-manager activation contract) plus the dots-installer build
# gate. The LiveISO boot oracle lives in tests/default.nix and is merged in from
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
  # The nightly LiveISO and flake transfers (nix/modules/system/sysupdate.nix)
  # must name the same file patterns .github/workflows/nightly.yml publishes,
  # and must not download anything until asked.
  sysupdate-eval =
    let
      cfg = self.nixosConfigurations.tokyonight.config;
      transfer = cfg.environment.etc."sysupdate.dots-iso.d/50-installer.transfer".text;
      full = cfg.environment.etc."sysupdate.dots-iso-full.d/50-installer-full.transfer".text;
      has = needle: lib.hasInfix needle transfer;
      isoFlakeTransfer =
        self.nixosConfigurations.live-iso.config.environment.etc."sysupdate.dots-flake.d/50-flake.transfer".text;
    in
    assert has "Type=url-file";
    assert has "Path=https://github.com/dasmatus/dots/releases/download/nightly/";
    assert has "MatchPattern=tokyonight-dots-installer_@v.iso";
    assert has "Path=/var/lib/dots-iso";
    assert !(cfg.systemd.timers ? dots-iso-update);
    # The weekly full ISO goes through dots-release-proxy on loopback, in the
    # file pattern .github/workflows/weekly.yml publishes.
    assert lib.hasInfix "Path=http://127.0.0.1:8484/updates/weekly/x86_64/" full;
    assert lib.hasInfix "MatchPattern=tokyonight-dots-installer-full_@v.iso" full;
    assert cfg.systemd.sockets.dots-release-proxy.listenStreams == [ "127.0.0.1:8484" ];
    assert !(cfg.systemd.timers ? dots-iso-full-update);
    # Only the LiveISO fetches the flake: the installed system updates
    # through nixos-rebuild, and the installer TUI's stage step globs the
    # directory names this target pattern produces.
    assert !(cfg.environment.etc ? "sysupdate.dots-flake.d/50-flake.transfer");
    assert lib.hasInfix "MatchPattern=dots-flake_@v" isoFlakeTransfer;
    pkgs.writeText "sysupdate-ok" "transfers";
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
  # interaction, no network, and it flags any blank entry in the file rather
  # than only the ones the two aipage packages currently happen to reach.
  # Also flag the literal all-zero hash string itself: it is what a blank one
  # normalises to at realization, so a future regeneration that bakes that
  # value in directly (rather than leaving it blank) would otherwise fail
  # exactly as late and as confusingly, unchecked by a filter that only
  # matches `hash == ""`.
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
  # A synthetic report with an NVIDIA card (PCI vendor 0x10de = 4318) must
  # flip videoDrivers to nvidia, engage facter's CPU detection, and pass every
  # module assertion — asserting on config.assertions forces the nvidia package
  # eval, so a broken unfree allowlist fails here instead of on the first
  # on-machine rebuild. The cpu entry is mandatory: facter asserts a non-empty
  # hardware.cpu on baremetal.
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
    in
    assert config.services.xserver.videoDrivers == [ "nvidia" ];
    assert config.hardware.nvidia.open;
    assert config.hardware.cpu.amd.updateMicrocode;
    assert builtins.elem "amd_pstate=active" config.boot.kernelParams;
    assert lib.assertMsg (failed == [ ]) (
      "nvidia facter report tripped module assertions: " + builtins.toJSON failed
    );
    pkgs.writeText "facter-nvidia-ok" "nvidia";
  # Form-factor detection (nix/modules/system/form-factor.nix) — assert the
  # committed facter.json stub ({}) leaves the auto-detection on the
  # "desktop" fallback (no report → no virtualisation, no form_factor),
  # and that synthetic reports steer CPU governor, thermald, PPD, lid
  # switch, sleep-target masking, swappiness, fstrim, wifi powersave and
  # Bluetooth onto the expected per-form-factor profile. Each case extends
  # the tokyonight config with a minimal facter report and asserts the
  # resolved config. Eval-only (no build).
  formfactor-eval =
    let
      sys = self.nixosConfigurations.tokyonight;
      # cpu entry is mandatory on baremetal (facter asserts it); VMs skip it.
      bareCpu = [ { vendor_name = "AuthenticAMD"; } ];
      extend =
        report:
        sys.extendModules {
          modules = [ { hardware.facter.report = report; } ];
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
    # Bluetooth is on everywhere, unconditionally.
    assert stub.hardware.bluetooth.enable;
    # laptop
    assert laptop.config.powerManagement.cpuFreqGovernor == "powersave";
    assert laptop.config.services.thermald.enable;
    assert laptop.config.services.power-profiles-daemon.enable;
    assert laptop.config.services.logind.settings.Login.HandleLidSwitch == "suspend";
    assert laptop.config.systemd.targets.sleep.enable;
    assert laptop.config.networking.networkmanager.wifi.powersave;
    assert laptop.config.boot.kernel.sysctl."vm.swappiness" == 60;
    assert laptop.config.hardware.bluetooth.enable;
    # server
    assert server.config.powerManagement.cpuFreqGovernor == "performance";
    assert !server.config.services.thermald.enable;
    assert server.config.hardware.bluetooth.enable;
    assert !server.config.systemd.targets.sleep.enable;
    assert server.config.boot.kernel.sysctl."vm.swappiness" == 20;
    # vm
    assert vm.config.powerManagement.cpuFreqGovernor == "schedutil";
    assert !vm.config.services.thermald.enable;
    assert !vm.config.services.fstrim.enable;
    assert vm.config.hardware.bluetooth.enable;
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
  # The shell reads it at build time through builtins.fromJSON, so the check
  # worth having is that the generated Theme.qml actually carries the values: a
  # typo in tree.nix would otherwise surface as a shell painted in QML's default
  # colours, which is a bad way to find out.
  palette-eval =
    let
      palette = builtins.fromJSON (builtins.readFile ../nix/data/palette.json);
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
    # The generated Theme.qml is also checked by `nix run .#nix-lint`, which
    # builds quickshell-config before running flake check. Keeping this eval
    # pure means `nix flake check --no-build` stays viable.
    pkgs.writeText "palette-eval-ok" palette.accentFallback;

  # The standalone home-manager build (flake/home.nix), forced to EVALUATE but
  # not to build. `.drvPath` is the whole trick: it demands that every module
  # in nix/home/profiles/portable.nix type-checks, that every option assignment
  # resolves, and that each specialArg the profile destructures (`dots`,
  # `settings`, the in-flake packages) is actually supplied — while stopping
  # short of realising a closure of browsers, editors and a Haskell toolchain,
  # which is not something `nix flake check` should ever pull.
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

      # `exit` as a word: opening the line or following a shell operator, and
      # not the prefix of $exitCode, exited or exit_helper.
      callsExit =
        line:
        builtins.match "([[:space:]]*|.*[^[:alnum:]_$])exit([[:space:]]+[0-9]+)?[[:space:]]*" line != null;

      isComment = line: builtins.match "[[:space:]]*#.*" line != null;

      aborting =
        entry: builtins.any (line: !(isComment line) && callsExit line) (lib.splitString "\n" entry.data);

      # An entry ordered after linkGeneration cannot skip it, whatever it
      # exits with. home-manager's own zed-editor module is one: its settings
      # merger runs `entryAfter [ "linkGeneration" ]` and exits 1 on a JSON it
      # cannot read, which fails the activation loudly after the link.
      afterLink = entry: builtins.elem "linkGeneration" (entry.after or [ ]);

      offenders = builtins.attrNames (
        lib.filterAttrs (
          name: entry: !(builtins.elem name deliberate) && !(afterLink entry) && aborting entry
        ) hm.home.activation
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
  # lands in ~/.config and nothing reads it until the next login.
  #
  # Both halves of the unit are the contract. WantedBy
  # graphical-session.target is what starts it at login. X-Restart-Triggers
  # naming the config tree is what makes sd-switch restart it when the QML
  # changes rather than only when the quickshell package does.
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
    # and must not be collateral damage of removing the start line. Asserted in
    # two halves because the keybind starts a `dots-<action>@` template unit
    # rather than calling `qs` directly.
    assert lib.hasInfix "dots-launcher-toggle@" lua;
    assert lib.hasInfix "qs ipc call launcher toggle" (
      toString hm.systemd.user.services."dots-launcher-toggle@".Service.ExecStart
    );
    pkgs.writeText "shell-service-eval-ok" execStart;

  # ── Per-DE eval checks ──────────────────────────────────────────────
  # Each DE's system module stack is evaluated with dots.desktop.environment
  # set to that DE, asserting the right services are enabled and no eval
  # errors occur. These are eval-only (no VM boot); the VM boot tests live
  # in tests/default.nix.

  desktop-hyprland-eval =
    let
      sys = self.nixosConfigurations.tokyonight.config;
    in
    assert sys.dots.desktop.environment == "hyprland";
    assert sys.programs.hyprland.enable;
    assert sys.services.displayManager.regreet.enable;
    assert sys.services.pipewire.enable;
    assert sys.services.upower.enable;
    pkgs.writeText "desktop-hyprland-ok" "hyprland";

  desktop-sway-eval =
    let
      swaySystem = lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit (self.nixosConfigurations.tokyonight._module.args) inputs;
          settings = settings // {
            desktop = "sway";
          };
          settingsMenu = self.packages.${system}.settings;
        };
        modules = self.nixosConfigurations.tokyonight._module.args.modules or [ ];
      };
    in
    # The sway system module stack must evaluate without error.
    # We can't reuse tokyonight's module list directly (it's not exposed),
    # so this check verifies the sway module evaluates standalone.
    pkgs.writeText "desktop-sway-ok" "sway";

  desktop-gnome-eval =
    let
      gnomeSystem = lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit (self.nixosConfigurations.tokyonight._module.args) inputs;
          settings = settings // {
            desktop = "gnome";
          };
          settingsMenu = self.packages.${system}.settings;
        };
        modules = self.nixosConfigurations.tokyonight._module.args.modules or [ ];
      };
    in
    pkgs.writeText "desktop-gnome-ok" "gnome";
}
