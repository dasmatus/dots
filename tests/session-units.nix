# The regression guard for the Hyprland/session refactor
# (nix/home/session/actions.nix, nix/home/session/default.nix,
# nix/home/hyprland.nix). Eval-only, in the style of `settings-eval` and
# `facter-stub-eval` in flake/checks.nix: no VM, no activation, just a
# standalone `home-manager.lib.homeManagerConfiguration` evaluated far enough
# to read `.config` back out, then five `assert`s over it.
#
# Built on a standalone home-manager configuration rather than
# `nixosConfigurations.tokyonight` because the latter cannot evaluate here at
# all: `nix/settings.nix` and `nix/facter.json` are symlinks into
# `/var/lib/dots`, and `facter.json` is mode 0600 root-owned, so any
# evaluation that walks through `nix/hosts.nix` dies with "Permission denied"
# regardless of `--impure`. A standalone home-manager evaluation needs
# neither file.
#
# `home.username`/`home.homeDirectory`/`home.stateVersion` below are
# home-manager's evaluation minimums, given obviously-fake values with no
# bearing on anything asserted here.
{
  pkgs,
  lib,
  inputs,
}:
let
  hm = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    # `dots.ai.ollama` is the one field nix/home/zed.nix reads (whether to
    # emit the Ollama language-model block); every other module pulled in
    # below is unconditional. No `hyprmon`/`wallpaperTui` args here any
    # more: both packages are gone from `main` (deleted in favour of QML),
    # and nix/home/hyprland.nix and nix/home/session/default.nix no longer
    # reference either.
    extraSpecialArgs = {
      dots.ai.ollama = false;
    };
    modules = [
      {
        home.username = "session-units-test";
        home.homeDirectory = "/home/session-units-test";
        home.stateVersion = "26.05";
        # Mirrors the one entry of nix/modules/core.nix's real
        # allowUnfreePredicate that this harness's module set actually forces:
        # nix/home/session/default.nix's `notes` exec default is
        # `pkgs.obsidian`, forced while evaluating `dots.session.exec` for
        # assertions 1-3 below. The production system gets this from
        # useGlobalPkgs; a standalone evaluation needs it spelled out.
        nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "obsidian" ];
        # Mirrors the `qt` block in nix/home/default.nix, and is load-bearing
        # for assertion 6 rather than decoration: home-manager's own qt module
        # writes `systemd.user.sessionVariables.QT_QPA_PLATFORMTHEME` (`qt5ct`,
        # from `platformTheme.name = "qtct"`), so a `dots.session.sessionVariables`
        # entry for that same key is a module conflict that aborts evaluation
        # outright — not a default something else overrides. Without this block
        # the harness leaves qt disabled, the key is unclaimed, and the exact
        # collision that broke `nixos-rebuild` evaluates clean here.
        # nix/home/default.nix is not imported wholesale instead because it
        # drags in the entire home (claude, librewolf, the aipage packages
        # threaded through specialArgs) for the sake of three Qt settings.
        qt = {
          enable = true;
          platformTheme.name = "qtct";
          style.name = "kvantum";
        };
      }
      ../nix/home/session
      ../nix/home/hyprland.nix
      ../nix/home/kitty.nix
      ../nix/home/zed.nix
    ];
  };
  cfg = hm.config;

  actions = import ../nix/home/session/actions.nix;

  # --- 1. Every generated `dots-*` ExecStart is an absolute store path. ----
  # The defect the whole refactor exists to fix: systemd refuses a relative
  # ExecStart, so a bare command name here is a unit that never runs.
  # home-manager's own ExecStart option runs `apply = lib.toList;`, so this is
  # always a list (of one entry, for every unit this module generates) even
  # though `mkUnit` assigns it a plain string — every element must be an
  # absolute store path.
  dotsServices = lib.filterAttrs (name: _: lib.hasPrefix "dots-" name) cfg.systemd.user.services;
  relativeExecStarts = lib.filterAttrs (
    _: unit: !(builtins.all (lib.hasPrefix "/nix/store/") unit.Service.ExecStart)
  ) dotsServices;
  relativeExecStartsMsg = lib.concatStringsSep ", " (
    lib.mapAttrsToList (
      name: unit: "${name} -> ${lib.concatStringsSep " " unit.Service.ExecStart}"
    ) relativeExecStarts
  );

  # --- 2. `app`/`action` units are templates. -------------------------------
  # A plain unit makes `systemctl start` a silent no-op on the second
  # keypress, so every app/action row that got a unit at all must have
  # gotten a `dots-<name>@.service` template, never a plain `dots-<name>`.
  appActionWithExec = builtins.filter (
    a: (a.kind == "app" || a.kind == "action") && (cfg.dots.session.exec ? ${a.name})
  ) actions;
  nonTemplateAppAction = builtins.filter (
    a: !(cfg.systemd.user.services ? "dots-${a.name}@")
  ) appActionWithExec;
  nonTemplateAppActionMsg = lib.concatMapStringsSep ", " (
    a:
    if cfg.systemd.user.services ? "dots-${a.name}" then
      "${a.name} (kind ${a.kind}) produced a plain dots-${a.name}.service instead of a template"
    else
      "${a.name} (kind ${a.kind}) produced no dots-${a.name}@.service template at all"
  ) nonTemplateAppAction;

  # --- 3. No action is stranded. --------------------------------------------
  # Every non-dispatch action needs a unit (daemon/startup: `dots-<name>`;
  # app/action: `dots-<name>@`) or a `dots.session.commands` entry. `lock` is
  # the deliberate exception — a command with no unit — and is accepted here
  # because it satisfies the `commands` half, not because its name is
  # special-cased.
  nonDispatchActions = builtins.filter (a: a.kind != "dispatch") actions;
  stranded = builtins.filter (
    a:
    !(cfg.systemd.user.services ? "dots-${a.name}")
    && !(cfg.systemd.user.services ? "dots-${a.name}@")
    && !(cfg.dots.session.commands ? ${a.name})
  ) nonDispatchActions;
  strandedMsg = lib.concatMapStringsSep ", " (a: "${a.name} (kind ${a.kind})") stranded;

  # --- 4. The rendered Hyprland Lua contains no command line. ---------------
  # home-manager's Hyprland module (modules/services/window-managers/hyprland
  # in the pinned home-manager source) writes the `configType = "lua"` output
  # to `xdg.configFile."hypr/hyprland.lua".text` — a plain Nix string, read
  # directly out of the evaluated config with no build involved. Every
  # `hl.dsp.exec_cmd(` call in it must be a `systemctl` invocation (the
  # indirection nix/home/session/default.nix's `commands` exists to
  # guarantee), and `hyprland.start` — the old exec-once startup hook —  must
  # not appear at all, because every daemon/startup action is now a systemd
  # unit instead.
  luaText = cfg.xdg.configFile."hypr/hyprland.lua".text;
  luaLines = lib.splitString "\n" luaText;
  execCmdLines = builtins.filter (l: lib.hasInfix "hl.dsp.exec_cmd(" l) luaLines;
  nonSystemctlExecCmdLines = builtins.filter (l: !(lib.hasInfix "systemctl" l)) execCmdLines;
  nonSystemctlExecCmdMsg = lib.concatStringsSep "\n  " nonSystemctlExecCmdLines;
  hyprlandStartLines = builtins.filter (l: lib.hasInfix "hyprland.start" l) luaLines;
  hyprlandStartMsg = lib.concatStringsSep "\n  " hyprlandStartLines;

  # --- 5. The session variables are intact. ---------------------------------
  # `XDG_CURRENT_DESKTOP`/`XDG_SESSION_DESKTOP` are always "Hyprland", so they
  # belong to the WM module (nix/home/hyprland.nix's own `env` list), never
  # to the WM-agnostic `dots.session.sessionVariables` default.
  sessionVars = cfg.systemd.user.sessionVariables;
  expectedSessionVars = [
    "XCURSOR_SIZE"
    "XCURSOR_THEME"
    "XDG_SESSION_TYPE"
    "QT_QPA_PLATFORM"
    "MOZ_ENABLE_WAYLAND"
    "NIXOS_OZONE_WL"
    "GDK_BACKEND"
  ];
  missingSessionVars = builtins.filter (v: !(sessionVars ? ${v})) expectedSessionVars;
  missingSessionVarsMsg = lib.concatStringsSep ", " missingSessionVars;
  wmOwnedVarsPresent = builtins.filter (v: sessionVars ? ${v}) [
    "XDG_CURRENT_DESKTOP"
    "XDG_SESSION_DESKTOP"
  ];
  wmOwnedVarsPresentMsg = lib.concatStringsSep ", " wmOwnedVarsPresent;

  # --- 6. `QT_QPA_PLATFORMTHEME` stays home-manager's to define. ------------
  # `QT_QPA_PLATFORM` above is genuinely session-owned; its `…THEME` sibling
  # is not, and the difference is not cosmetic. The qt block in the harness
  # module above makes home-manager's qt module claim the key, so a
  # `dots.session.sessionVariables` entry for it does not lose an override
  # race — it aborts the evaluation with "has conflicting definition values",
  # which is precisely how `nixos-rebuild switch` broke: the key used to be a
  # Hyprland `env` entry (compositor environment, a separate namespace that
  # merely disagreed at runtime) and moving it into this module put both
  # definitions in one place.
  #
  # Asserting the value rather than mere presence pins the winner too. `gtk3`
  # — the value this module used to carry — makes Qt load the GTK platform
  # theme, which ignores qt6ct and Kvantum outright and would silently strand
  # the wallpaper-accent retint in nix/home/quickshell/qml/wallpaper/Kvantum.qml.
  qtPlatformTheme = sessionVars.QT_QPA_PLATFORMTHEME or null;

  # --- 7. Screenshot units don't get torn down mid-write. -------------------
  # hyprshot's last line backgrounds the actual grab and races it against a
  # foreground watcher, `checkRunning` (.hyprshot-wrapped:132-140), that
  # sleeps one second and then exits the instant `slurp` is gone
  # (.hyprshot-wrapped:309) — while `grim`, `wl-copy` and `notify-send` are
  # still running. Under systemd's default KillMode=control-group, the whole
  # cgroup is torn down with the process it was tracking: the unit reports
  # success and no file appears. `KillMode = "process"` on every
  # `dots-screenshot-*` unit (nix/home/hyprland.nix's job to set) is what
  # keeps the capture alive long enough to finish.
  screenshotUnits = lib.filterAttrs (name: _: lib.hasPrefix "dots-screenshot-" name) (
    cfg.systemd.user.services
  );
  unprotectedScreenshotUnits = lib.filterAttrs (
    _: unit: (unit.Service.KillMode or "control-group") != "process"
  ) screenshotUnits;
  unprotectedScreenshotUnitsMsg = lib.concatStringsSep ", " (
    lib.mapAttrsToList (
      name: unit: "${name} (KillMode = ${unit.Service.KillMode or "control-group"})"
    ) unprotectedScreenshotUnits
  );
in
assert lib.assertMsg (relativeExecStarts == { })
  "tests/session-units.nix: dots-* systemd unit(s) with a non-absolute ExecStart: ${relativeExecStartsMsg}. systemd refuses a relative ExecStart, so this unit never runs.";
assert lib.assertMsg (nonTemplateAppAction == [ ])
  "tests/session-units.nix: app/action(s) with an `exec` entry that did not produce a `dots-<name>@.service` template: ${nonTemplateAppActionMsg}. A plain unit makes `systemctl start` a silent no-op on the second keypress.";
assert lib.assertMsg (stranded == [ ])
  "tests/session-units.nix: action(s) with neither a unit nor a dots.session.commands entry: ${strandedMsg}. Every non-dispatch row in nix/home/session/actions.nix needs one or the other.";
assert lib.assertMsg (nonSystemctlExecCmdLines == [ ]) ''
  tests/session-units.nix: hyprland.lua hl.dsp.exec_cmd() call(s) that are not a systemctl invocation:
  ${nonSystemctlExecCmdMsg}
  Every app/action bind must run through dots.session.commands, never a bare command line.'';
assert lib.assertMsg (hyprlandStartLines == [ ]) ''
  tests/session-units.nix: hyprland.lua still has a hyprland.start exec-once hook:
  ${hyprlandStartMsg}
  Every daemon/startup action is a systemd unit now (nix/home/session/default.nix); nothing should launch from this hook any more.'';
assert lib.assertMsg (missingSessionVars == [ ])
  "tests/session-units.nix: systemd.user.sessionVariables is missing portable variable(s): ${missingSessionVarsMsg}.";
assert lib.assertMsg (wmOwnedVarsPresent == [ ])
  "tests/session-units.nix: systemd.user.sessionVariables carries WM-owned variable(s) that belong only to nix/home/hyprland.nix: ${wmOwnedVarsPresentMsg}.";
assert lib.assertMsg (qtPlatformTheme == "qt5ct") ''
  tests/session-units.nix: systemd.user.sessionVariables.QT_QPA_PLATFORMTHEME is ${
    if qtPlatformTheme == null then "unset" else ''"${qtPlatformTheme}"''
  }, expected "qt5ct" from home-manager's qt module.
  That key belongs to `qt.platformTheme.name` in nix/home/default.nix, not to
  dots.session.sessionVariables — defining it in both is an eval conflict that
  takes the whole `nixos-rebuild` down, and "gtk3" in particular bypasses
  qt6ct and Kvantum and breaks the wallpaper retint.'';
assert lib.assertMsg (unprotectedScreenshotUnits == { })
  "tests/session-units.nix: dots-screenshot-* unit(s) without KillMode = \"process\": ${unprotectedScreenshotUnitsMsg}. hyprshot's checkRunning watcher (.hyprshot-wrapped:132-140) exits the instant slurp is gone while grim/wl-copy/notify-send are still writing, and systemd's default KillMode=control-group tears down the whole cgroup with the process it tracked — silent data loss. nix/home/hyprland.nix is where KillMode = \"process\" belongs.";
assert lib.assertMsg (screenshotUnits != { })
  "tests/session-units.nix: found no dots-screenshot-* unit(s) at all — check 7 would pass vacuously if the screenshot actions were renamed out from under it.";
pkgs.writeText "session-units-ok" ''
  execstart-absolute
  app-action-templated
  no-stranded-actions
  hyprland-lua-clean
  session-variables-intact
  qt-platform-theme-unclaimed
  screenshot-units-protected
''
