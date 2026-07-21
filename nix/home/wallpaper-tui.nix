# awww-based TUI wallpaper changer — terminal replacement for waytrogen.
# Declarative Nix options own the settings; the Textual script in
# ./wallpaper-tui.py (packaged via writers.writePython3Bin, then wrapped so it
# can inject the read-only Nix-store base paths for the SVG tint targets) reads
# them and writes only runtime overrides.
#
# Two-file split (avoids waytrogen.nix's read-only-symlink workaround):
#   ~/.config/wallpaper-tui/config.json  — declarative, read-only, from Nix
#   ~/.local/state/wallpaper-tui/state.json — writable runtime picks, by the TUI
# Nix is the source of truth for folder/outputs/defaults; the TUI overrides per
# output for the session; --restore applies the effective merge. To make a pick
# permanent, declare it in Nix instead of relying on state.
#
# The script also derives an accent color from the applied wallpaper and tints
# Hyprland borders, the Rofi theme, GTK 3/4, the Kvantum (Qt) theme and the
# MoreWaita icon theme. The SVG base dirs for Kvantum/icons are passed in via
# WALLPAPER_TUI_KVANTUM_BASE / WALLPAPER_TUI_ICON_BASE by the wrapper below so
# the Python stays free of store-path globbing (and unit-testable with tmp
# dirs). See docs/superpowers/specs/2026-07-21-wallpaper-tint-design.md.
{
  config,
  lib,
  pkgs,
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

  wallpaper-tui-py =
    pkgs.writers.writePython3Bin "wallpaper-tui.py"
      {
        libraries = [
          pkgs.python3Packages.textual
          pkgs.python3Packages.pillow
        ];
        flakeIgnore = [ "E501" ];
      }
      (builtins.readFile ./wallpaper-tui.py);

  # Thin wrapper that injects the read-only Nix-store base paths for the SVG
  # tint targets (Kvantum + MoreWaita) before exec-ing the Python script. Each
  # is overridable via env so tests/dev can point at a tmp base.
  wallpaper-tui =
    pkgs.writeShellScriptBin "wallpaper-tui"
      ''
        export WALLPAPER_TUI_KVANTUM_BASE="''${WALLPAPER_TUI_KVANTUM_BASE:-${pkgs.catppuccin-kvantum}/share/Kvantum/catppuccin-frappe-blue}"
        export WALLPAPER_TUI_ICON_BASE="''${WALLPAPER_TUI_ICON_BASE:-${pkgs.morewaita-icon-theme}/share/icons/MoreWaita}"
        export PATH="${lib.makeBinPath [ pkgs.chafa ]}:$PATH"
        exec ${lib.getExe wallpaper-tui-py} "$@"
      '';

  declarativeConfig = builtins.toJSON {
    wallpaper_folder = cfg.wallpaperFolder;
    recursive = cfg.recursive;
    current_output = cfg.currentOutput;
    transition_type = cfg.transitionType;
    transition_duration = cfg.transitionDuration;
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

    transitionType = lib.mkOption {
      type = lib.types.enum [
        "none" "simple" "fade" "left" "right" "top" "bottom"
        "wipe" "wave" "grow" "center" "any" "outer" "random"
      ];
      default = "grow";
      description = "awww transition effect between wallpapers.";
    };

    transitionDuration = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = "awww transition duration in seconds.";
    };

    cacheInterval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd OnCalendar for the preview-cache timer.";
    };

    outputs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          path = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default wallpaper path for this output (null = none).";
          };
          mode = lib.mkOption {
            type = lib.types.enum modes;
            default = "fill";
            description = "awww --resize mode (was swaybg scaling mode).";
          };
          fillColor = lib.mkOption {
            type = lib.types.str;
            default = "#d2a1a1";
            description = "Fill color (hex) for letterbox modes.";
          };
        };
      });
      default = { };
      description = "Per-output declarative wallpaper defaults.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile."wallpaper-tui/config.json".text = declarativeConfig;
    home.packages = [ wallpaper-tui ];

    # Periodically regenerate the wallpaper thumbnail cache the TUI reads for
    # instant chafa previews. oneshot + daily timer (cadence via
    # cfg.cacheInterval); scoped to the graphical session so it doesn't run on
    # a headless box. ExecStart is the wrapper so chafa/Pillow/env are present.
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