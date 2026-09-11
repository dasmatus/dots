# Quickshell is the desktop shell. Bar, notifications, OSD, launcher and the
# settings form all live in one QML tree (nix/home/desktop/quickshell/qml) instead of
# the waybar + dunst + eww + rofi + beamenu pile they replace, so there is one
# palette, one IPC socket and one process to reason about.
#
# pkgs.quickshell rather than a flake input, for the reason flake.nix:48-58
# gives about Hyprland: nixpkgs' build is on cache.nixos.org, a pinned input's
# prebuilt is not, and the difference is a compositor-sized source build on
# every rebuild.
{
  pkgs,
  lib,
  config,
  dots,
  ...
}:
let
  cfg = config.programs.dots-shell;

  tree = import ./tree.nix {
    inherit pkgs;
    inherit (cfg) quicklinks snippets;
    keybinds = import ../keybinds.nix;
    stateHome = config.xdg.stateHome;
    cacheHome = config.xdg.cacheHome;
  };
in
{
  # The unit that prebuilds files/Files.qml's search index. Its own file
  # because it is a service and a timer with nothing else to say, and
  # because the path it writes has to agree with the one tree.nix bakes
  # into Theme.qml, both derive it from config.xdg.cacheHome.
  imports = [ ./files-index.nix ];

  options.programs.dots-shell = {
    # qml/monitors/Watcher.qml's ruleset, replacing nix/home/hyprmon.nix's
    # xdg.configFile."hyprmon/rules.json" (deleted alongside the crate, see
    # docs/superpowers/plans/2026-08-26-qs-migration-2b-monitor-surface.md).
    # Field names are plan.js's own (matchName/matchDescription, camelCase
    # throughout) rather than the crate's serde ones (match_name/
    # match_description): rules.json is no longer a Rust struct's wire
    # format read by anything else, so there is no reason to keep the
    # underscore spelling and then adapt it back at read time the way
    # tst_monitor_parity.qml's adaptRule still has to for the frozen fixture
    # captured from the crate.
    monitorRules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Rule name, for logging only. Matching is by matchName/matchDescription.";
            };
            matchName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Regex against the monitor's connector name (e.g. \"^DP-1$\").";
            };
            matchDescription = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Regex against the monitor's EDID description.";
            };
            resolution = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "\"WxH\", \"WxH@R\", or unset for Hyprland's own preferred mode.";
            };
            scale = lib.mkOption {
              type = lib.types.float;
              description = "Hyprland monitor scale.";
            };
            position = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "\"XxY\" to pin this monitor absolutely; unset to continue the horizontal layout.";
            };
            transform = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Hyprland's monitor transform enum (0-7).";
            };
            vrr = lib.mkOption {
              type = lib.types.enum [
                "off"
                "left"
                "right"
                "auto"
              ];
              default = "off";
              description = "Variable refresh rate mode.";
            };
          };
        }
      );
      # The two-monitor setup from AGENTS.md: a 27" 1080p 240Hz VRR panel
      # (DP-1, ASUS VG279QM) on the left and a 25" 1200p 60Hz panel
      # (HDMI-A-1, LG 25UM58) on its right, plus a "*" fallback so a
      # hotplugged projector gets preferred/auto/1 instead of Hyprland's
      # mirror-default, verbatim from the deleted hyprmon.nix.
      default = [
        {
          name = "laptop-edp";
          matchName = "^eDP-1$";
          scale = 1.0;
          vrr = "off";
        }
        {
          name = "primary-240hz";
          matchName = "^DP-1$";
          matchDescription = "VG279QM";
          resolution = "1920x1080@240";
          scale = 1.0;
          vrr = "left";
        }
        {
          name = "secondary-60hz";
          matchName = "^HDMI-A-1$";
          matchDescription = "25UM58";
          resolution = "2560x1200";
          scale = 1.0;
          vrr = "off";
        }
        {
          name = "*";
          scale = 1.0;
          vrr = "off";
        }
      ];
      description = "Monitor layout rules, read by the shell's hotplug watcher.";
    };

    quicklinks = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Row title, and the word typed to reach it.";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "URL, or a shell command when `command` is set.";
            };
            command = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Run `target` through sh rather than opening it.";
            };
          };
        }
      );
      default = [ ];
      description = "Launcher quicklinks.";
    };

    snippets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Row title.";
            };
            text = lib.mkOption {
              type = lib.types.lines;
              description = "Text copied to the clipboard.";
            };
          };
        }
      );
      default = [ ];
      description = "Launcher text snippets.";
    };
  };

  config = {
    home.packages = [
      pkgs.quickshell

      # The launcher's clipboard history reads wl-paste --watch, and its file
      # provider shells out to fd, which the wallpaper picker's own file
      # listing (qml/wallpaper/Picker.qml, Rotation.qml) also shells out to.
      pkgs.wl-clipboard
      pkgs.fd

      # devices.js shells out to both: lsblk for the device list, udisksctl
      # for mount, unmount and power-off.
      pkgs.util-linux
      pkgs.udisks2

      # awww (formerly swww) is the wallpaper daemon: hyprland.nix's
      # hyprland.start launches awww-daemon, and Picker.qml/Rotation.qml both
      # shell out to the `awww` client. Moved here from the now-deleted
      # wallpaper-tui.nix, which used to be the only consumer.
      pkgs.awww

      # gio trash (files/operations.js's trashArgv) needs `gio` on PATH.
      # glib, not trash-cli: it is already pulled in by this desktop's own
      # GTK closure, and both honour the same .Trash-$uid convention on a
      # removable filesystem's own top level.
      pkgs.glib
    ];

    # Lands at $XDG_CONFIG_HOME/quickshell, which is where a bare `qs` looks
    # for shell.qml, so the compositor's exec line needs no --path.
    xdg.configFile."quickshell".source = tree;

    # Watcher.qml's rules file. Deliberately a sibling of quickshell/ rather
    # than inside it: quickshell/ is home-manager's whole-directory symlink
    # into the built tree above (tree.nix's runCommand output), so nothing
    # can be dropped alongside shell.qml at runtime. Arrange.qml's
    # overrides.json needs exactly that, and lives here too, unmanaged by
    # home-manager, once written once.
    xdg.configFile."dots-shell/monitors.json".text = builtins.toJSON {
      rules = cfg.monitorRules;
    };

    # qml/idle/IdleWatcher.qml's two thresholds, beside monitors.json and out
    # of the store tree for the identical reason. Seconds, straight from
    # dots.idle.* (nix/modules/dots.nix, defaulting to nix/system/defaults.nix
    # and editable from the settings panel's Session page).
    #
    # A file rather than a value baked into the generated Theme.qml: the
    # watcher reads it through FileView with watchChanges, so a switch that
    # changes a timeout re-arms the running shell instead of waiting for the
    # next login. Theme.qml is also the palette, and how long this machine
    # waits before locking itself is not a colour.
    xdg.configFile."dots-shell/idle.json".text = builtins.toJSON {
      blankSeconds = dots.idle.blankTimeout;
      lockSeconds = dots.idle.lockTimeout;
    };

    # The shell runs as a unit rather than as a child of the compositor.
    # `hyprland.start` fires once at compositor boot (nix/home/desktop/hyprland.nix),
    # so anything launched from there stays dead until the next login. A
    # rebuild puts new QML in ~/.config and nothing reads it. As a unit it
    # starts at login through graphical-session.target and comes back on
    # switch, the way hyprmon and gammastep already do.
    #
    # ExecStart is a bare binary with no --path, so the running instance is
    # keyed to ~/.config/quickshell/shell.qml. That is the path the keybinds'
    # `qs ipc call …` clients resolve; pointing the daemon at the store tree
    # instead would leave every one of them talking to an instance that does
    # not exist.
    #
    # Which is why the tree is named in X-Restart-Triggers instead. Nothing
    # else in this unit changes when the QML does, so without it sd-switch
    # compares two identical unit files and restarts the shell only when the
    # quickshell package itself moves.
    systemd.user.services.quickshell = {
      Unit = {
        Description = "Quickshell desktop shell";
        PartOf = [ "graphical-session.target" ];
        # `graphical-session-pre.target` alone only orders this unit after
        # PRE-session setup (uwsm's env preloader,
        # `wayland-wm-env@hyprland.service`). It says nothing about the
        # compositor itself having finished starting. And `WantedBy =
        # [ "graphical-session.target" ]` below is a Wants-style PULL, not
        # an ordering constraint: without an explicit `After=` naming it,
        # this unit's start job is queued the moment
        # graphical-session-pre.target is up, running IN PARALLEL with, not
        # after, uwsm actually bringing Hyprland the rest of the way, and
        # Hyprland creating `%t/hypr` (the directory `ConditionPathExists`
        # below checks) is a step in that parallel startup, not something
        # graphical-session-pre.target already guarantees. This is not
        # theoretical: tests/session-boot.nix caught it directly. This
        # unit's condition check failed, permanently, about 7 seconds
        # before uwsm's own "Wait for WAYLAND_DISPLAY and other variables"
        # step finished. `ConditionPathExists` is evaluated once, at queue
        # time, and systemd never re-evaluates a condition-skipped unit on
        # its own, so losing this race is not "starts a bit late", it is
        # the shell silently never starting for the rest of the session.
        #
        # `graphical-session.target` itself, though, IS safe to order
        # after, because uwsm's own unit graph makes REACHING it conditional
        # on the compositor's readiness, not merely on session setup having
        # begun: `wayland-wm@hyprland.service` (uwsm's per-compositor "main
        # service") is `Type=notify` and does not report itself active
        # until Hyprland, via `uwsm finalize`, run from the compositor's
        # own startup, sends systemd a READY=1 notification, which in
        # practice happens once Hyprland has created its runtime directory
        # and exported WAYLAND_DISPLAY, exactly the state this unit's
        # condition needs. `wayland-session@hyprland.target` then
        # `Requires=` that service and is itself `BindsTo=`/`Before=`
        # `graphical-session.target`, so `graphical-session.target` cannot
        # reach "active" before Hyprland has reported ready. Ordering after
        # it, instead of a fixed `sleep`, ties this unit to that real event:
        # whatever uwsm/Hyprland's own startup takes, short or long, this
        # unit waits for the actual signal rather than a guessed duration
        # that could still be too short (or needlessly long) on different
        # hardware. It is also upstream's own documented shape for exactly
        # this class of unit: uwsm ships `share/doc/uwsm/example-units/
        # {waybar,hyprpaper}.service`, both commented "order startup after
        # WM" and both using plain `After = graphical-session.target` +
        # `WantedBy = graphical-session.target`, the same pairing applied
        # here.
        After = [
          "graphical-session-pre.target"
          "graphical-session.target"
        ];
        # The bar's workspace and window pills read Hyprland's socket, so a
        # non-Hyprland session has no shell to run. The monitor watcher the
        # shell now carries needs that socket too, for the same reason the
        # hyprmon unit it replaced was gated this way. Left in place
        # alongside the ordering fix above as a second, cheap guard: it is
        # what would catch a session that reached graphical-session.target
        # by some other path (a future compositor swap, say) without this
        # directory actually existing, rather than trusting ordering alone.
        ConditionPathExists = [ "%t/hypr" ];
        X-Restart-Triggers = [ "${tree}" ];
      };
      Service = {
        ExecStart = lib.getExe pkgs.quickshell;

        # Explicit rather than inherited, because the inherited default is
        # what made a real crash undiagnosable. tests/session-boot.nix caught
        # quickshell with NRestarts=2 and `journalctl --user -u quickshell`
        # returning "No entries" -- it had crashed twice and left nothing
        # behind to say why.
        #
        # The cause is that quickshell keeps its OWN log store and exposes it
        # through `quickshell log`, rather than writing crash detail to
        # stderr, so the journal only ever holds whatever Qt itself printed.
        # Setting these does not move quickshell's own logs into the journal
        # and is not meant to: it pins the Qt-level output that DOES reach
        # stderr, so a QML error or a Qt plugin failure is journald's problem
        # and survives a restart loop, instead of depending on whatever
        # systemd's default happens to be for user units on some future
        # release.
        #
        # For quickshell's own detail, `quickshell log` is the command, and
        # the session-boot test's failure path now dumps all three sources
        # (per-user journal, system journal keyed on _SYSTEMD_USER_UNIT, and
        # `quickshell log`) rather than only the first.
        StandardOutput = "journal";
        StandardError = "journal";

        # Every icon this shell draws, the SystemTray items' `.icon`
        # property, Quickshell.iconPath() in the launcher and elsewhere,
        # resolves through Qt's QIcon::fromTheme(), whose theme name comes
        # from the active Qt *platform* theme. nix/home/default.nix's
        # `qt.platformTheme.name = "qtct"` makes home-manager export
        # `QT_QPA_PLATFORMTHEME=qt5ct` session-wide, but quickshell is a Qt6
        # binary and its Qt6 plugin path ships libqt6ct.so, libqgtk3.so and
        # libqxdgdesktopportal.so, no libqt5ct.so. Confirmed live against
        # the running process: `tr '\0' '\n' < /proc/$MAINPID/environ` shows
        # `QT_QPA_PLATFORMTHEME=qt5ct` and no `_QT6` counterpart, so the
        # platform theme plugin silently fails to load and Qt falls back to
        # QGenericUnixTheme, whose icon theme is "hicolor". Hence every tray
        # and launcher icon rendering as its app's own vendor icon instead of
        # Papirus.
        #
        # Measured against a throwaway quickshell instance logging
        # Quickshell.iconPath(name, true): qt5ct, qt6ct and even an unset
        # QT_QPA_PLATFORMTHEME all resolve "folder"/"firefox"/
        # "utilities-terminal" to "". Firefox is the decisive one, since
        # nothing on this machine installs that icon into hicolor, only
        # Papirus does. Only `gtk3` resolves all three. libqgtk3.so reads
        # `gtk-icon-theme-name` out of ~/.config/gtk-3.0/settings.ini, which
        # qml/wallpaper/Gtk.qml keeps pointed at the current Papirus variant
        # on every wallpaper pick, so tray, launcher rows, workspaces,
        # focused window and notifications all land on that same retinted
        # Papirus.
        #
        # This override rides the UNIT's own Environment, never
        # dots.session.sessionVariables: tests/session-units.nix's check 6
        # asserts the session stays on `qt5ct`, because a session-wide
        # `gtk3` bypasses qt6ct and Kvantum for every *other* Qt app and
        # strands qml/wallpaper/Kvantum.qml's wallpaper-accent retint.
        # Overriding it only here is safe precisely because quickshell
        # renders QML and never instantiates a QStyle, so Kvantum has
        # nothing to say in this one process. No X-Restart-Triggers edit is
        # needed alongside it: the unit file itself changes, and that is
        # what sd-switch diffs to decide on a restart. qml/bar/Tray.qml
        # needs no change to go with this. proton.vpn.app.gtk's IconName is
        # an absolute path into its own store output, which no icon theme
        # can reach, and it correctly keeps its vendor icon regardless.
        Environment = [ "QT_QPA_PLATFORMTHEME=gtk3" ];

        Restart = "on-failure";
        RestartSec = 2;

        # Only the seven directives with no plausible conflict with this
        # unit's job. Held back on purpose, per the comment above this
        # unit's own Qt6/QV4 JIT reasoning: MemoryDenyWriteExecute is a
        # likely breakage (QML's JS engine JITs), RestrictAddressFamilies
        # (the shell reaches Wayland, D-Bus, and network-status sources)
        # and ProtectHome/ProtectSystem (the shell reads wallpapers, theme
        # state, and other files across $HOME) are all untested here and
        # plausible breakage too, so none of the four are added. Rationale
        # for the seven that are safe matches mkUnit's baseline in
        # session/default.nix: rendering the desktop shell has no need for
        # clock/hostname/kernel-log/cgroup/personality/realtime/setuid-
        # setgid access.
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
