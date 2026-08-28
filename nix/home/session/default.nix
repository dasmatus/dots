# Turns the pure-data table in ./actions.nix into systemd --user units, and
# publishes, per action, the command a window manager binds to reach it.
# After this module lands, no WM module needs to know a command line, only a
# unit name (daemon/startup) or a `dots.session.commands.<name>` string
# (app/action) — that indirection is the whole point of the change; see
# ./actions.nix's header for why the table itself carries no command field.
#
# This module is WM-agnostic on purpose: it takes no WM-specific argument and
# reaches for no WM-specific package, so it evaluates on its own with no
# tiling WM in scope at all. Two `execDefaults` entries this table describes
# — `reload` and `hyprmon-apply` — are Hyprland-only, and are therefore not
# defined here; see the `exec` option's description below for where they
# actually come from. `wallpaperTui` is deliberately NOT taken here either:
# the raw binary loses the tint backend (see nix/home/wallpaper-tui.nix's
# wrapper), so wallpaper-restore below goes through the read-only
# `config.programs.wallpaper-tui.finalPackage` option that module now
# exposes instead.
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

  # Both screenshot binds are shell pipelines (capture, then notify), so
  # systemd cannot take them as a bare ExecStart — built the same way
  # nix/home/dots-repo.nix builds its clone script, as a derivation whose own
  # store path is the executable. Every binary inside is an absolute store
  # path: this script's ExecStart context is a `dots-<name>@.service`
  # instance, not an interactive shell, so nothing on $PATH can be assumed.
  #
  # This replaces `hyprshot`, which is not packaged anywhere in this repo (so
  # both binds were already dead) and only speaks Hyprland's own IPC; grim +
  # slurp work on any wlroots compositor.
  mkScreenshotScript =
    { name, grim }:
    pkgs.writeShellScript "dots-${name}" ''
      set -euo pipefail
      pictures="$(${lib.getExe' pkgs.xdg-user-dirs "xdg-user-dir"} PICTURES 2> /dev/null || true)"
      pictures="''${pictures:-$HOME/Pictures}"
      ${lib.getExe' pkgs.coreutils "mkdir"} -p "$pictures"
      # hyprshot's own default stamp format, kept for continuity with what
      # this replaces.
      file="$pictures/Screenshot_$(${lib.getExe' pkgs.coreutils "date"} +%Y-%m-%d-%H%M%S).png"
      ${grim} "$file"
      ${lib.getExe pkgs.libnotify} "Screenshot saved in $pictures"
    '';

  screenshotOutput = mkScreenshotScript {
    name = "screenshot-output";
    # No `-o`: captures every output composited, matching "whole screen".
    grim = lib.getExe pkgs.grim;
  };
  screenshotRegion = mkScreenshotScript {
    name = "screenshot-region";
    grim = ''${lib.getExe pkgs.grim} -g "$(${lib.getExe pkgs.slurp})"'';
  };

  # The command line for every non-dispatch, non-`lock` action that has one.
  # Keyed by `name` (actions.nix's join key), never by `dispatch`.
  execDefaults = {
    # daemons
    awww-daemon = lib.getExe' pkgs.awww "awww-daemon";
    quickshell = qs;
    nm-applet = "${lib.getExe pkgs.networkmanagerapplet} --indicator";

    # startup
    wallpaper-restore = "${lib.getExe config.programs.wallpaper-tui.finalPackage} --restore";

    # apps
    terminal = lib.getExe config.programs.kitty.package;
    file-manager = lib.getExe pkgs.nautilus;
    notes = lib.getExe pkgs.obsidian;
    editor = lib.getExe config.programs.zed-editor.package;

    # actions — everything but `lock`, which has no unit at all (see below)
    launcher-toggle = "${qs} ipc call launcher toggle";
    cheatsheet-toggle = "${qs} ipc call cheatsheet toggle";
    settings-toggle = "${qs} ipc call settings toggle";
    screenshot-output = "${screenshotOutput}";
    screenshot-region = "${screenshotRegion}";
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
    XCURSOR_SIZE = "24";
    XCURSOR_THEME = "Adwaita";
    XDG_SESSION_TYPE = "wayland";
    QT_QPA_PLATFORM = "wayland";
    QT_QPA_PLATFORMTHEME = "gtk3";
    MOZ_ENABLE_WAYLAND = "1";
    NIXOS_OZONE_WL = "1";
    GDK_BACKEND = "wayland,x11";
  };

  # Every action in `cfg.exec` gets a unit; `lock` (kind = "action") is the
  # one entry with no `exec` and therefore no unit at all.
  unitActions = builtins.filter (a: cfg.exec ? ${a.name}) nonDispatchActions;

  # `dots-awww-daemon.service` is what the naming rule below produces for the
  # `awww-daemon` action (kind = "daemon" → `dots-<name>.service`). Spelled
  # out as a literal, rather than re-deriving it, because it has exactly one
  # caller.
  awwwDaemonUnit = "dots-awww-daemon.service";

  unitName = a: if isDaemonLike a then "dots-${a.name}" else "dots-${a.name}@";

  mkUnit =
    a:
    {
      Unit = {
        Description = a.desc;
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
      }
      // lib.optionalAttrs (a.name == "wallpaper-restore") {
        # awww-daemon must be up before `wallpaper-tui --restore` talks to
        # it. `After` on a Type=simple daemon only waits for the fork, not
        # for readiness, and `awww img` retries on its own anyway, so this
        # is ordering rather than a race fix.
        After = [
          "graphical-session.target"
          awwwDaemonUnit
        ];
        Wants = [ awwwDaemonUnit ];
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
        `reload` and `hyprmon-apply` are the two entries this module does
        not supply: both are Hyprland-only commands (`hyprctl reload`,
        `hyprmon apply`), so nix/home/hyprland.nix contributes them directly
        as its own ordinary assignment to this same `attrsOf str` option — see
        the comment on `default` above for why that has to be a plain
        assignment on both sides rather than living in either module's
        inline `default`. A second WM module (e.g. a future sway.nix) does
        the same for whichever entries it owns, with `lib.mkForce` where it
        needs to replace one rather than add it.
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
