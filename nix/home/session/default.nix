# Turns the pure-data table in ./actions.nix into systemd --user units, and
# publishes, per action, the command a window manager binds to reach it.
# After this module lands, no WM module needs to know a command line, only a
# unit name (daemon/startup) or a `dots.session.commands.<name>` string
# (app/action) — that indirection is the whole point of the change; see
# ./actions.nix's header for why the table itself carries no command field.
#
# This module is WM-agnostic on purpose: it takes no WM-specific argument and
# reaches for no WM-specific package, so it evaluates on its own with no
# tiling WM in scope at all. Four `execDefaults` entries this table describes
# — `reload` and the three `screenshot-*` actions — are Hyprland-only, and are
# therefore not defined here; see the `exec` option's description below for
# where they actually come from.
#
# Quickshell is deliberately NOT one of the daemons this module generates a
# unit for, even though it is exactly the kind of long-running, no-key thing
# `actions.nix` otherwise tables. `nix/home/quickshell/default.nix` owns its
# own `systemd.user.services.quickshell` outside this table, carrying an
# `X-Restart-Triggers = [ "${tree}" ]` that ties its restart to the built QML
# tree rather than to a package bump — this generator's `mkUnit` has no
# concept of a per-unit restart trigger, only the blanket `PartOf`/`After`
# every row gets, so absorbing quickshell here would silently drop that and
# leave the shell serving stale QML after a config-only rebuild. hyprmon and
# wallpaper-tui, which used to back the `hyprmon-apply` and
# `wallpaper-restore` rows below (the latter via `config.programs.wallpaper-
# tui.finalPackage`), are gone outright — deleted on `main` in favour of QML —
# rather than ported, so neither name appears in this module any more.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dots.session;
  actions = import ./actions.nix;

  nonDispatchActions = builtins.filter (a: a.kind != "dispatch") actions;
  actionNames = map (a: a.name) actions;

  isDaemonLike = a: a.kind == "daemon" || a.kind == "startup";

  # Repeated store-path lookups, named once. `qs` needs `getExe'` rather
  # than `getExe` because quickshell's `meta.mainProgram` is "quickshell"
  # (the qs binary is a second executable in the same package) — verified
  # against the pinned nixpkgs.
  qs = lib.getExe' pkgs.quickshell "qs";
  systemctl = lib.getExe' pkgs.systemd "systemctl";

  # The command line for every non-dispatch, non-`lock` action that has one.
  # Keyed by `name` (actions.nix's join key), never by `dispatch`. No
  # `quickshell` entry: that daemon's unit lives in
  # nix/home/quickshell/default.nix instead (see the module header above).
  execDefaults = {
    # daemons
    awww-daemon = lib.getExe' pkgs.awww "awww-daemon";
    nm-applet = "${lib.getExe pkgs.networkmanagerapplet} --indicator";

    # apps
    terminal = lib.getExe config.programs.kitty.package;
    notes = lib.getExe pkgs.obsidian;
    editor = lib.getExe config.programs.zed-editor.package;

    # actions — everything but `lock`, which has no unit at all (see below)
    launcher-toggle = "${qs} ipc call launcher toggle";
    file-manager = "${qs} ipc call files toggle";
    cheatsheet-toggle = "${qs} ipc call cheatsheet toggle";
    settings-toggle = "${qs} ipc call settings toggle";
    wallpaper-toggle = "${qs} ipc call wallpaper toggle";
    arrange-toggle = "${qs} ipc call arrange toggle";
    volume-mute = "${qs} ipc call osd volumeMute";
    mic-mute = "${qs} ipc call osd micToggle";
    touchpad-toggle = "${qs} ipc call osd touchpadToggle";
    privacy-toggle = "${qs} ipc call osd privacyToggle";
    volume-up = "${qs} ipc call osd volumeUp";
    volume-down = "${qs} ipc call osd volumeDown";
    brightness-up = "${qs} ipc call osd brightnessUp";
    brightness-down = "${qs} ipc call osd brightnessDown";
  };

  # `commands` defaults: daemon/startup get no entry — nothing binds them,
  # `graphical-session.target` starts them. app/action get the
  # `$RANDOM`-suffixed instance start below, EXCEPT `lock`, which has no unit
  # to start at all.
  #
  # Sourced from `unitActions` (kind app/action AND has an `exec` entry, i.e.
  # actually got a unit above) rather than from `actions` by `kind` alone: an
  # app/action row that loses its `exec` entry must also lose its default
  # `commands` entry, or it would keep "successfully" starting a
  # `dots-<name>@.service` that no longer exists, and the `missingCommand`
  # assertion below would never notice the drift.
  #
  # `$RANDOM` is not a typo: `systemctl start` on an already-active unit is a
  # silent no-op, which would cap kitty at one window and serialise held
  # media-key repeats. Hyprland's exec runs the bound command through
  # `/bin/sh`, which is bash on NixOS (verified 5.3 here), and
  # nix/home/hyprland.nix:771 already leans on that same shell expansion, so
  # this is consistent with the existing config rather than a new trick.
  commandDefaults =
    (lib.listToAttrs (
      map (
        a:
        lib.nameValuePair a.name ''${systemctl} --user start --no-block "dots-${a.name}@$RANDOM.service"''
      ) (builtins.filter (a: a.kind == "app" || a.kind == "action") unitActions)
    ))
    // {
      # `lock` bypasses the raw `hyprlock` binary on purpose: hyprlock.service
      # (nix/home/hyprland.nix) is already `WantedBy=lock.target` and wires
      # `OnSuccess=unlock.target`; running the binary directly skipped all of
      # that. Absolute path to systemctl, same as everywhere else here.
      lock = "${systemctl} --user start lock.target";
    };

  sessionVariablesDefault = {
    # `XDG_CURRENT_DESKTOP`/`XDG_SESSION_DESKTOP` are excluded on purpose:
    # both are always "Hyprland", so that pair belongs to the WM module, not
    # to this WM-agnostic one.
    #
    # `QT_QPA_PLATFORMTHEME` is excluded for a different reason: home-manager's
    # own `qt` module already owns that key, and nix/home/default.nix enables it
    # (`platformTheme.name = "qtct"`, `style.name = "kvantum"`), so the qt module
    # writes `qt5ct` into this very attrset. Defining it here too is a hard eval
    # conflict, not a shadowed default — the module system refuses to pick a
    # winner and the rebuild dies. It only became an error when this table
    # absorbed the value: it used to be a Hyprland `env` entry, which is
    # compositor environment rather than `systemd.user.sessionVariables`, so the
    # two sat in separate namespaces and merely disagreed at runtime (Hyprland's
    # children saw `gtk3`, systemd units saw `qt5ct`). `qt5ct` is the value the
    # repo actually wants: `gtk3` makes Qt load the GTK platform theme, which
    # ignores qt6ct and Kvantum entirely and would silently kill the
    # wallpaper-accent retint that quickshell's wallpaper/Kvantum.qml performs.
    XCURSOR_SIZE = "24";
    XCURSOR_THEME = "Adwaita";
    XDG_SESSION_TYPE = "wayland";
    QT_QPA_PLATFORM = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    NIXOS_OZONE_WL = "1";
    GDK_BACKEND = "wayland,x11";
  };

  # Every action in `cfg.exec` gets a unit; `lock` (kind = "action") is the
  # one entry with no `exec` and therefore no unit at all.
  unitActions = builtins.filter (a: cfg.exec ? ${a.name}) nonDispatchActions;

  unitName = a: if isDaemonLike a then "dots-${a.name}" else "dots-${a.name}@";

  # A behaviour change from the old `exec-once` world, worth flagging where
  # anyone editing a unit here will see it: `exec-once` children of the
  # compositor were invisible to home-manager and untouched by a rebuild
  # until the next login. Every `daemon`/`startup` action below is instead a
  # systemd --user unit `WantedBy = [ "graphical-session.target" ]`, so
  # home-manager activation's `sd-switch` now restarts any of them that are
  # active and whose unit file changed — `awww-daemon` and `nm-applet`
  # included, mid-session, on an otherwise unrelated package bump. This is
  # deliberate: a declarative unit taking effect the moment `home-manager
  # switch` runs is the point of making it a unit at all, not a regression to
  # route around. Anyone who wants a specific unit left alone across a switch
  # instead has `X-SwitchMethod` (sd-switch's own escape hatch, set in a
  # unit's `[Install]`/`[Service]` section) available to reach for — nothing
  # here sets it on any unit, since the repo's other WantedBy-graphical-
  # session units (`protonvpn-app.service`) already restart on switch too
  # with no opt-out, and picking a unit to exempt is a call for whoever owns
  # that unit, not a default this generator imposes.
  mkUnit =
    a:
    {
      Unit = {
        Description = a.desc;
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      };
      Service = {
        ExecStart = cfg.exec.${a.name};
        Slice = if isDaemonLike a then "session.slice" else "app-graphical.slice";
      }
      // lib.optionalAttrs (a.kind == "startup" || a.kind == "action") {
        Type = "oneshot";
      }
      // lib.optionalAttrs (a.kind == "daemon") {
        Restart = "on-failure";
        # 2s: long enough that a daemon stuck in a crash loop doesn't peg a
        # core, short enough that a transient DBus/Wayland-socket hiccup is
        # back before it's noticed.
        RestartSec = 2;
      };
    }
    // lib.optionalAttrs (isDaemonLike a) {
      # `app`/`action` units are templates (`dots-<name>@.service`, see
      # `unitName`): nothing ever wants them by name, the WM starts a fresh
      # instance itself via `commands`, so they get no [Install] section at
      # all — home-manager drops an empty section from the rendered unit.
      Install.WantedBy = [ "graphical-session.target" ];
    };

  # `%i` — the template instance specifier systemd substitutes into a
  # `dots-<name>@.service` unit — is a nonce and is deliberately unused in
  # every one of these unit bodies: every instance runs the identical
  # ExecStart, and it is the `$RANDOM` suffix in `commandDefaults` above that
  # turns each `systemctl start` into a distinct instance rather than a
  # no-op against one already running. Called out here because an unused
  # `%i` reads as a bug to the next person who looks at a template unit.
  services = lib.listToAttrs (map (a: lib.nameValuePair (unitName a) (mkUnit a)) unitActions);

  missingCommand = builtins.filter (
    a: !(cfg.exec ? ${a.name}) && !(cfg.commands ? ${a.name})
  ) nonDispatchActions;

  danglingExecKeys = builtins.filter (name: !(builtins.elem name actionNames)) (
    builtins.attrNames cfg.exec
  );
in
{
  options.dots.session = {
    exec = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      # NOT `default = execDefaults` here: an option's own inline `default`
      # is the *weakest* possible definition in the module system (priority
      # 1500, below even `lib.mkDefault`'s 1000) and a whole ATTRSET is one
      # definition, not a bag of independently-prioritised keys — so the
      # moment any other module gives `dots.session.exec` a plain value at
      # all, that plain value wins outright and the inline default is
      # discarded WHOLESALE, including keys the other module never
      # mentioned. `execDefaults` is instead assigned below, in this
      # module's own `config`, at the same ordinary priority a second
      # contributor uses — verified with a standalone `lib.evalModules`
      # probe: two plain per-module attrsets to the same `attrsOf` option
      # merge by key, but an inline `default` competing against a plain
      # value from elsewhere does not.
      default = { };
      description = ''
        Command line for an actions.nix entry, keyed by `name`. Every
        non-dispatch action needs one of `exec` or `commands`; `lock` is the
        one exception, deliberately absent here (see `commands.lock`).
        `reload` and the three `screenshot-*` actions are the entries this
        module does not supply: they are Hyprland-only commands (`hyprctl
        reload`, and hyprshot, which speaks Hyprland's own IPC), so
        nix/home/hyprland.nix contributes them directly as its own ordinary
        assignment to this same `attrsOf str` option — see the comment on
        `default` above for why that has to be a plain assignment on both
        sides rather than living in either module's inline `default`. A
        second WM module (e.g. a future sway.nix) does the same for
        whichever entries it owns, with `lib.mkForce` where it needs to
        replace one rather than add it.
      '';
    };

    commands = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = commandDefaults;
      description = ''
        What a window manager binds a key to, keyed by `name`. Defaulted
        from `exec` + `kind` (see `commandDefaults` in this module):
        daemon/startup get no entry, app/action get a `$RANDOM`-suffixed
        `systemctl --user start --no-block` of their template unit. `lock`
        is the exception with no unit of its own.
      '';
    };

    sessionVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = sessionVariablesDefault;
      description = ''
        Portable session variables, fed to `systemd.user.sessionVariables`
        so the systemd user manager (and anything it launches, e.g. a
        unit-started Obsidian or Zed) sees the same environment as a
        compositor child — without this, such a process falls back to
        XWayland. `nix/home/hyprland.nix` reads this option for its own
        `settings.env` and adds the two per-WM variables itself, so the two
        lists can never drift out of step; `XDG_CURRENT_DESKTOP`/
        `XDG_SESSION_DESKTOP` are intentionally not here — both are always
        "Hyprland", so they belong to the WM module.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = missingCommand == [ ];
        message = ''
          dots.session: action(s) missing both an `exec` and a `commands` entry: ${
            lib.concatMapStringsSep ", " (a: a.name) missingCommand
          }. Every non-dispatch row in nix/home/session/actions.nix needs one or the other in nix/home/session/default.nix.
        '';
      }
      {
        assertion = danglingExecKeys == [ ];
        message = ''
          dots.session.exec has key(s) naming no action in nix/home/session/actions.nix: ${lib.concatStringsSep ", " danglingExecKeys}.
        '';
      }
    ];

    # A plain assignment, not the `exec` option's inline `default` — see the
    # comment on that option for why: this has to compete at the same
    # priority as nix/home/hyprland.nix's own `dots.session.exec` assignment
    # for the two to merge by key instead of one replacing the other whole.
    dots.session.exec = execDefaults;

    systemd.user.sessionVariables = cfg.sessionVariables;
    systemd.user.services = services;
  };
}
