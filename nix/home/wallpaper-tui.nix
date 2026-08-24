# awww-based TUI wallpaper changer — terminal replacement for waytrogen.
# Applies talk to awww-daemon over its socket, which is what let the pidfile,
# the SIGTERM-and-respawn dance and the ~/.hyprtile/config.json sync all go
# when HyprTile was removed. It also restored two things that had regressed:
# per-output wallpapers, since awww takes --outputs, and transitions.
# Declarative Nix options own the settings; the Rust crate in ../../rust/wallpaper-tui
# (built once at the flake level as packages.${system}.wallpaper-tui, then
# wrapped here so it can inject the read-only Nix-store base paths for the SVG
# tint targets) reads them and writes only runtime overrides.
#
# Two-file split (avoids waytrogen.nix's read-only-symlink workaround):
#   ~/.config/wallpaper-tui/config.json  — declarative, read-only, from Nix
#   ~/.local/state/wallpaper-tui/state.json — writable runtime picks, by the TUI
# Nix is the source of truth for folder/outputs/defaults; the TUI overrides per
# output for the session; --restore applies the effective merge. To make a pick
# permanent, declare it in Nix instead of relying on state.
#
# The binary also derives an accent color from the applied wallpaper and tints
# Hyprland borders, the Rofi theme, GTK 3/4, the Kvantum (Qt) theme and the
# MoreWaita icon theme. The SVG base dirs for Kvantum/icons are passed in via
# WALLPAPER_TUI_KVANTUM_BASE / WALLPAPER_TUI_ICON_BASE by the wrapper below so
# the Rust code stays free of store-path globbing (and unit-testable with tmp
# dirs). Previews are pure-Rust half-block cells (no chafa). See
# docs/superpowers/specs/2026-07-21-wallpaper-tint-design.md.
{
  config,
  lib,
  pkgs,
  wallpaperTui,
  ...
}:

let
  cfg = config.programs.wallpaper-tui;
  modes = [
    "fill"
    "stretch"
    "fit"
    "center"
    "tile"
  ];

  wallpaper-tui-bin = wallpaperTui;

  # Thin wrapper that injects the read-only Nix-store base paths for the SVG
  # tint targets (Kvantum + MoreWaita) before exec-ing the Rust binary. Each is
  # overridable via env so tests/dev can point at a tmp base. Also puts pywal on
  # PATH so the ``Pywal`` tint backend can shell out to ``wal``.
  wallpaper-tui = pkgs.writeShellScriptBin "wallpaper-tui" ''
    export PATH="${lib.makeBinPath [ pkgs.pywal ]}:$PATH"
    export WALLPAPER_TUI_KVANTUM_BASE="''${WALLPAPER_TUI_KVANTUM_BASE:-${pkgs.catppuccin-kvantum}/share/Kvantum/catppuccin-frappe-blue}"
    export WALLPAPER_TUI_ICON_BASE="''${WALLPAPER_TUI_ICON_BASE:-${pkgs.morewaita-icon-theme}/share/icons/MoreWaita}"
    exec ${lib.getExe wallpaper-tui-bin} "$@"
  '';

  declarativeConfig = builtins.toJSON {
    wallpaper_folder = cfg.wallpaperFolder;
    recursive = cfg.recursive;
    current_output = cfg.currentOutput;
    tint_backend = cfg.tintBackend;
    transition = cfg.transition;
    transition_duration = cfg.transitionDuration;
    transition_fps = toString cfg.transitionFps;
    outputs = lib.mapAttrs (_: o: {
      path = o.path;
      mode = o.mode;
      fill_color = o.fillColor;
    }) cfg.outputs;
  };
in
{
  options.programs.wallpaper-tui = {
    enable = lib.mkEnableOption "awww-based TUI wallpaper changer";

    wallpaperFolder = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Dokumente/codeberg/personal/dots/Wallpapers/wh";
      description = "Folder scanned for wallpapers.";
    };

    recursive = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to descend into subdirectories of wallpaperFolder.";
    };

    currentOutput = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Output focused by default in the TUI.";
    };

    # Transitions came back with awww. The enum is awww's own
    # --transition-type vocabulary; the TUI passes these straight through.
    transition = lib.mkOption {
      type = lib.types.enum [
        "none"
        "simple"
        "fade"
        "left"
        "right"
        "top"
        "bottom"
        "wipe"
        "wave"
        "grow"
        "center"
        "outer"
        "random"
      ];
      default = "fade";
      description = "Animation used when the wallpaper changes.";
    };

    transitionDuration = lib.mkOption {
      type = lib.types.str;
      default = "1";
      description = "Transition length in seconds (awww --transition-duration).";
    };

    transitionFps = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Transition frame rate (awww --transition-fps).";
    };

    tintBackend = lib.mkOption {
      type = lib.types.enum [
        "internal"
        "pywal"
      ];
      default = "pywal";
      description = "Palette backend used to extract the wallpaper accent.";
    };

    cacheInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar for the preview-cache timer.";
    };

    outputs = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Default wallpaper path for this output (null = none).";
            };
            mode = lib.mkOption {
              type = lib.types.enum modes;
              default = "fill";
              description = "Scaling mode (swaybg vocabulary, mapped to awww img --resize).";
            };
            fillColor = lib.mkOption {
              type = lib.types.str;
              default = "#d2a1a1";
              description = "Fill color (hex) for letterbox modes.";
            };
          };
        }
      );
      default = { };
      description = "Per-output declarative wallpaper defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."wallpaper-tui/config.json".text = declarativeConfig;

    # Wallpaper plugin identity lives in beamenu.nix, which random_wp.nix
    # also contributes to; this is the interactive-picker command plus its
    # Ctrl+K alternates.
    # No desktop entry ships with the crate, so the picker was previously
    # reachable only through the launcher plugin below or a shell. This puts
    # it in the app list and the app grid, and its `actions` become the row's
    # indented children and its Ctrl+K entries — see the same reasoning in
    # nix/home/hyprmon.nix, including why `terminal` stays false here.
    xdg.desktopEntries.wallpaper-tui = {
      name = "Wallpapers";
      genericName = "Wallpaper Picker";
      comment = "Pick a wallpaper and re-tint the desktop from it";
      icon = "${wallpaper-tui-bin}/share/icons/hicolor/scalable/apps/wallpaper-tui.svg";
      exec = "${lib.getExe config.programs.kitty.package} -e ${lib.getExe wallpaper-tui}";
      terminal = false;
      categories = [
        "Settings"
        "DesktopSettings"
      ];
      settings.Keywords = "wallpaper;background;theme;accent;tint;";
      # `Actions=` is emitted in attribute-name order, and that order is what
      # the launcher draws, so the ids are named to sort the way the menu
      # should read: restore is the everyday one, rebuilding thumbnails is
      # housekeeping.
      actions = {
        restore = {
          name = "Restore Last Wallpaper";
          exec = "${lib.getExe wallpaper-tui} --restore";
        };
        thumbnails = {
          name = "Rebuild Preview Cache";
          exec = "${lib.getExe wallpaper-tui} --cache-previews";
        };
      };
    };

    # What the desktop entry cannot do: render the live state. `awww query`
    # prints the image currently on each output, which is exactly the thing
    # you open a wallpaper tool to check.
    #
    # The picker stays `terminal` and stays an action: it is a full-screen
    # ratatui program, and the canvas gives its child three pipes rather than
    # a pty, so a TUI cannot run inside the pane at all (its alt-screen escape
    # would even leak `1049h` into the log as literal text).
    programs.beamenu.plugins.wallpaper.commands = [
      {
        id = "status";
        title = "Wallpaper Status";
        description = "The image on each output right now";
        mode = "view";
        exec = [
          "awww"
          "query"
        ];
        actions = [
          {
            id = "pick";
            title = "Pick Wallpaper";
            mode = "terminal";
            exec = [ "wallpaper-tui" ];
          }
          {
            id = "restore";
            title = "Restore Last Wallpaper";
            mode = "exec";
            exec = [
              "wallpaper-tui"
              "--restore"
            ];
          }
        ];
      }
    ];

    home.packages = [
      wallpaper-tui
      # awww (formerly swww; nixpkgs renamed it, and so did the binaries) is the
      # wallpaper daemon. hyprland.start launches awww-daemon and
      # the TUI shells out to `awww img`. Both binaries come from this package.
      pkgs.awww
    ];

    # Periodically regenerate the wallpaper thumbnail cache the TUI reads for
    # instant half-block previews. oneshot + daily timer (cadence via
    # cfg.cacheInterval); scoped to the graphical session so it doesn't run on
    # a headless box. ExecStart is the wrapper so the tint-base env is present.
    systemd.user.services.wallpaper-preview-cache = {
      Unit = {
        Description = "Cache wallpaper-tui preview thumbnails";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe wallpaper-tui} --cache-previews";
      };
    };

    systemd.user.timers.wallpaper-preview-cache = {
      Unit.Description = "Periodic wallpaper-tui preview cache refresh";
      Timer = {
        OnCalendar = cfg.cacheInterval;
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
