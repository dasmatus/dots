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
  settings = (import ../nix/defaults.nix) // (import ../nix/settings.nix);
in
{
  dots-installer = self.packages.${system}.dots-installer;
  settings-eval = pkgs.writeText "settings-ok" (
    builtins.concatStringsSep "\n" [
      settings.username
      settings.hostname
      (builtins.concatStringsSep "," settings.disks)
      settings.swapSize
      settings.gitName
      settings.gitEmail
    ]
  );
  # The committed facter.json stub ({}) must leave every detection off,
  # including the nvidia if-then-else in nix/hosts.nix.
  facter-stub-eval =
    assert
      self.nixosConfigurations.tokyonight.config.services.xserver.videoDrivers == [
        "modesetting"
      ];
    pkgs.writeText "facter-stub-ok" "modesetting";
  # A synthetic report with an NVIDIA card (PCI vendor 0x10de = 4318) must
  # flip videoDrivers to nvidia, engage facter's CPU detection, and pass
  # every module assertion — asserting on config.assertions forces the
  # nvidia package eval, so a broken unfree allowlist fails here instead of
  # on the first on-machine rebuild. The cpu entry is mandatory: facter
  # asserts a non-empty hardware.cpu on baremetal.
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
    assert failed == [ ];
    pkgs.writeText "facter-nvidia-ok" "nvidia";
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
  # Asserts the in-flake aipage build (nix/aipage.nix) evaluates, the
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
  # Form-factor detection (nix/modules/form-factor.nix) — assert the
  # committed facter.json stub ({}) leaves the auto-detection on the
  # "desktop" fallback (no report → no virtualisation, no form_factor),
  # and that synthetic reports steer CPU governor, thermald, PPD, lid
  # switch, sleep-target masking, swappiness, fstrim, bluetooth, and
  # wifi powersave onto the expected per-form-factor profile. Each case
  # extends the tokyonight config with a minimal facter report and
  # asserts the resolved config. Eval-only (no build).
  formfactor-eval =
    let
      sys = self.nixosConfigurations.tokyonight;
      # cpu entry is mandatory on baremetal (facter asserts it); VMs skip it.
      bareCpu = [ { vendor_name = "AuthenticAMD"; } ];
      mkReport = report: {
        hardware.facter.report = report;
      };
      extend = report: sys.extendModules { modules = [ (mkReport report) ]; };

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
    assert stub.hardware.bluetooth.enable;
    # laptop
    assert laptop.config.powerManagement.cpuFreqGovernor == "powersave";
    assert laptop.config.services.thermald.enable;
    assert laptop.config.services.power-profiles-daemon.enable;
    assert laptop.config.services.logind.settings.Login.HandleLidSwitch == "suspend";
    assert laptop.config.systemd.targets.sleep.enable;
    assert laptop.config.networking.networkmanager.wifi.powersave;
    assert laptop.config.boot.kernel.sysctl."vm.swappiness" == 60;
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

  # rust/palette.json is the single source of truth for the system palette
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
      palette = builtins.fromJSON (builtins.readFile ../rust/palette.json);
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
    assert carries palette.colors.bg;
    assert carries palette.accentFallback;
    assert carries palette.fonts.ui;
    pkgs.writeText "palette-eval-ok" palette.accentFallback;

  # nix/modules/agentmem.nix, guarded against the three ways it has already
  # broken at activation. Each of those reached a rebuild because parsing a
  # module is not evaluating it, and `nix flake check` cannot run on a bare
  # checkout here (nix/settings.nix is a symlink into /var/lib/dots), so on a
  # workstation nothing forced these paths until switch time. In CI, where the
  # settings stub exists, this is the gate that fires first.
  agentmem-eval =
    let
      sys = self.nixosConfigurations.tokyonight.config;
      migrate = sys.systemd.services.agentmem-migrate;
      script = migrate.script;

      # Everything after the extension install. `_migrations` has to land in
      # there: the schema belongs to pg_agentmem, so creating the table before
      # the extension exists is the ordering that fails.
      afterExtension =
        let
          parts = lib.splitString "CREATE EXTENSION IF NOT EXISTS pg_agentmem" script;
        in
        if builtins.length parts >= 2 then builtins.elemAt parts 1 else "";

      # Migration filenames must be 0001..000N with no gap and no repeat. Two
      # agents once both produced a `0004`, under different names, and git
      # merged all three with no textual conflict because the collision is in
      # the sequence rather than in any line.
      sqlNames = lib.sort (a: b: a < b) (
        builtins.filter (lib.hasSuffix ".sql") (
          builtins.attrNames (builtins.readDir ../nix/modules/agentmem/migrations)
        )
      );
      prefixes = map (f: builtins.substring 0 4 f) sqlNames;
      expected = lib.genList (i: lib.fixedWidthNumber 4 (i + 1)) (builtins.length sqlNames);
    in
    # Forcing finalPackage is the whole point of the next line: it is what
    # evaluates the `extensions` list, and naming a contrib extension there
    # (pg_trgm, unaccent) fails with "attribute 'pg_trgm' missing".
    assert lib.hasPrefix "postgresql-and-plugins" sys.services.postgresql.finalPackage.name;
    # Pinned major. The repo sets no system.stateVersion and autoupgrades
    # daily, so an unpinned package moves psqlSchema and dataDir under a live
    # cluster the moment nixpkgs gains a new major.
    assert lib.hasPrefix "18." sys.services.postgresql.package.version;
    assert !sys.services.postgresql.enableTCPIP;
    # The runner is its own unit. `services.postgresql.postStart` is not an
    # option at all, and referencing this config at all is what catches that.
    assert migrate.serviceConfig.Type == "oneshot";
    assert migrate.serviceConfig.User == sys.dots.username;
    assert builtins.elem "postgresql.service" migrate.after;
    assert builtins.elem "postgresql-setup.service" migrate.after;
    # Ordering and ownership: install the extension, then the bookkeeping
    # table, and never create the schema by hand. pgrx's #[pg_schema] emits
    # its own CREATE SCHEMA, and an extension script may only skip an object
    # the extension already owns, so a second creator blocks it permanently.
    assert lib.hasInfix "_migrations" afterExtension;
    assert !(lib.hasInfix "CREATE SCHEMA IF NOT EXISTS agentmem" script);
    # A cluster left by the older bootstrap still carries an unowned schema,
    # which no retry repairs, so the runner has to clear it first.
    assert lib.hasInfix "DROP SCHEMA agentmem CASCADE" script;
    assert prefixes == expected;
    # State that outlives a reboot: root is a tmpfs, so without the
    # persistence entry the cluster is re-initdb'd empty every boot, and the
    # backup has to sit under that same persisted parent rather than the
    # module default on /var/backup.
    assert builtins.any (
      d: (if builtins.isAttrs d then d.directory else d) == "/var/lib/postgresql"
    ) sys.environment.persistence."/persist".directories;
    assert lib.hasPrefix "/var/lib/postgresql/" sys.services.postgresqlBackup.location;
    pkgs.writeText "agentmem-eval-ok" (builtins.concatStringsSep "\n" prefixes);
}
