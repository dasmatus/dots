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

  # nix/data/sandbox-policy.json is the committed, read-only defaults every
  # per-app sandbox launch resolves against (rust/dots-sandbox). Modelled on
  # palette-eval above, then taken one step further: that check only proves
  # the Nix side agrees with itself, but here there are genuinely two
  # parsers of the same file — this eval-time half and the Rust binary's
  # own `serde` schema — and this repo's convention for exactly that shape
  # of risk is a single committed source of truth with a check proving it
  # round-trips through both. The asserts below catch a malformed file
  # cheaply, at eval time, before any derivation realizes; the
  # `dots-sandbox policy validate` build afterwards is what actually proves
  # the two parsers still agree, since an eval-only assert here and the
  # crate's own `serde`/`validate_strict` logic can drift independently of
  # each other without this.
  sandbox-policy-eval =
    let
      policyPath = ../nix/data/sandbox-policy.json;
      policy = builtins.fromJSON (builtins.readFile policyPath);

      # The crate itself has no compiled-in app catalog — the defaults file
      # *is* the catalog (see resolve_app in rust/dots-sandbox/src/policy.rs)
      # — so "an app id the crate knows" is checked here against every real
      # launchable surface this repo actually offers: the flake's own
      # `nix run .#<app>` list, plus every other surface `wrapSandboxed`
      # confines outside that list — the quickshell pill bar's desktop
      # launchers and the `home.packages` MCP servers (edupage-mcp) that
      # ship no launcher at all. Nothing in Nix enumerates either set's
      # app ids today, so the second half is a hand-kept list; a new
      # sandboxed app — launcher or MCP server — needs a line here as
      # much as it needs one in the policy file.
      knownFlakeApps = builtins.attrNames self.apps.${system};
      knownDesktopApps = [
        "global-settings"
        "computer-use-linux"
        "kitty"
        "junction"
        "bitwarden"
        "zed"
        "claude-desktop"
        "edupage-mcp"
      ];
      knownApps = knownFlakeApps ++ knownDesktopApps;

      appIds = builtins.attrNames policy.apps;
      unknownApps = builtins.filter (id: !(builtins.elem id knownApps)) appIds;

      apps = builtins.attrValues policy.apps;
      capStates = lib.flatten (map (app: builtins.attrValues (app.caps or { })) apps);
      pathStates = lib.flatten (map (app: map (p: p.state) (app.paths or [ ])) apps);
      validStates = [
        "allow"
        "deny"
        "ask"
      ];
      # `allow-once` is a session-state answer, never a persisted one (see
      # PolicyState's doc comment) — this is the same rejection `serde`
      # gives the binary for free by only ever having three variants to
      # deserialize into, restated here since raw JSON parsing has no such
      # enum to lean on.
      badStates = builtins.filter (s: !(builtins.elem s validStates)) (capStates ++ pathStates);

      unconfinedApps = lib.filterAttrs (_: app: app.unconfined or false) policy.apps;
      # Missing and blank are the same failure (`require_reason` trims
      # before checking emptiness), so both collapse into one match here.
      badReasons = builtins.filter (
        id: builtins.match "[[:space:]]*" (unconfinedApps.${id}.reason or "") != null
      ) (builtins.attrNames unconfinedApps);
    in
    # SUPPORTED_VERSION in rust/dots-sandbox/src/policy.rs. Bumping the
    # schema is deliberate on both sides at once, never on just one.
    assert policy.version == 1;
    assert lib.assertMsg (unknownApps == [ ]) (
      "nix/data/sandbox-policy.json names app id(s) this repo does not define: "
      + builtins.concatStringsSep ", " unknownApps
    );
    assert lib.assertMsg (badStates == [ ]) (
      "nix/data/sandbox-policy.json has a grant state other than allow/deny/ask: "
      + builtins.concatStringsSep ", " badStates
    );
    assert lib.assertMsg (badReasons == [ ]) (
      "nix/data/sandbox-policy.json marks unconfined app(s) with no non-empty reason: "
      + builtins.concatStringsSep ", " badReasons
    );
    pkgs.runCommand "sandbox-policy-validate-ok"
      {
        nativeBuildInputs = [ self.packages.${system}.dots-sandbox ];
      }
      ''
        dots-sandbox policy validate ${policyPath} | tee $out
      '';

  # The standalone home-manager build (flake/home.nix), forced to EVALUATE but
  # not to build. `.drvPath` is the whole trick: it demands that every module
  # in nix/home/profiles/portable.nix type-checks, that every option assignment
  # resolves, and that each specialArg the profile destructures
  # (`dots`, `settings`, `wrapSandboxed`, the in-flake packages) is actually
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

  # Every home.activation entry, guarded against ending the run early.
  # home-manager splices the whole DAG into one bash script, so an `exit` in
  # any entry stops the activation there — including linkGeneration, which is
  # the step that puts ~/.config/quickshell, and every other managed file, on
  # disk. Nothing about that failure is loud: the script exits 0, systemd
  # reports success, and home.packages still arrive because useUserPackages
  # installs them through the NixOS closure rather than through this script.
  # The symptom is a ~/.config that quietly stops tracking the repo, which is
  # how a whole desktop shell reached the store and never reached the machine.
  #
  # checkLinkTargets is upstream's and its `|| exit 1` is the point: a file
  # collision has to stop the run before anything is linked. Every other entry
  # fails here instead, a home-manager bump that adds one included — read what
  # the new entry does before deciding its name belongs below.
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
