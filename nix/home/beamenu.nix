# beamenu, the Raycast-style launcher the desktop is built around, replacing
# HyprTile. SUPER+D opens it; SUPER+SHIFT+E opens it on the system commands.
#
# Two store paths back it. `beamenu-view` is bemenu carrying the patch series
# in nix/patches/beamenu, and ships the library; `beamenu` is the Rust binary
# that links it, owns the event loop and implements the providers. Only the
# second is user-facing, and it arrives via extraSpecialArgs like
# wallpaperTui/hyprmon/settingsMenu.
#
# None of HyprTile's resident-scratchpad machinery came across. That existed
# to hide SDL3 and GL startup: a parked instance in a special workspace, a
# window rule, a focus-loss patch and a flock retry in a toggle script.
# Layer-shell plus cairo starts in tens of milliseconds, so SUPER+D just runs
# the binary.
#
# Unlike ~/.hyprtile/config.json, everything here is a real symlink into the
# store. beamenu never writes its own configuration; the only mutable state is
# the frecency store and the clipboard log, both under $XDG_STATE_HOME.
{
  beamenuPkg,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.beamenu;

  # Lifted from nix/home/rofi/tokyonight.rasi so the launcher reads as the
  # same surface the old rofi menus did: same Tokyonight ramp, same 16px
  # corner, same 720px body. bemenu wants #RRGGBBAA, and the alpha on the
  # background is the only opacity knob it has. rofi got its translucency
  # from `transparency: "real"`, which has no bemenu equivalent.
  theme = {
    background = "#1a1b26f2"; # rofi @bg
    foreground = "#a9b1d6ff"; # rofi @fg-alt
    muted = "#6a6f87ff"; # rofi @fg
    selected_background = "#2d3252ff"; # rofi @selected-bg
    selected_foreground = "#c0caf5ff";
    border = "#2d3252ff";
    heading = "#7aa2f7ee"; # rofi @accent, which coloured its prompt
    font = "Lilex Nerd Font 12";
    accent = cfg.accent;
  };

  # The Rust side reads snake_case; the Nix options are camelCase to match the
  # rest of this repo's option style, so rename on the way out.
  configJson = {
    inherit theme;
    lines = cfg.lines;
    width_factor = cfg.widthFactor;
    icon_size = cfg.iconSize;
    line_height = cfg.lineHeight;
    search_height = cfg.searchHeight;
    radius = cfg.radius;
    terminal = cfg.terminal;
    file_manager = cfg.fileManager;
    disabled = cfg.disabledProviders;
  };

  # Screen recording, replacing hyprtile-screener. wl-screenrec has no daemon
  # and no toggle of its own, so the pidfile is the toggle: SIGINT makes it
  # finalise the container rather than leave a truncated file, which SIGKILL
  # would.
  recordToggle = pkgs.writeShellScriptBin "beamenu-record" ''
    set -eu
    state="''${XDG_RUNTIME_DIR:-/tmp}/beamenu-record.pid"
    out="$(${pkgs.xdg-user-dirs}/bin/xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")"

    if [ -f "$state" ] && kill -0 "$(cat "$state")" 2>/dev/null; then
      kill -INT "$(cat "$state")"
      rm -f "$state"
      ${pkgs.libnotify}/bin/notify-send "Recording saved in $out"
      exit 0
    fi

    mkdir -p "$out"
    file="$out/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4"
    ${pkgs.wl-screenrec}/bin/wl-screenrec -f "$file" >/dev/null 2>&1 &
    echo $! > "$state"
    ${pkgs.libnotify}/bin/notify-send "Recording started"
  '';
in
{
  options.programs.beamenu = {
    enable = lib.mkEnableOption "the beamenu launcher" // {
      default = true;
    };

    lines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 9;
      description = "Result rows shown at once; the panel height follows from this.";
    };

    widthFactor = lib.mkOption {
      type = lib.types.float;
      default = 0.375;
      description = ''
        Fraction of the output width the panel occupies. bemenu has no
        absolute width, only this factor, so the default is rofi's 720px
        expressed against a 1920px output.
      '';
    };

    iconSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "Row icon edge length in pixels.";
    };

    lineHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 44;
      description = "Result row height in pixels.";
    };

    searchHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = 56;
      description = "Search row height in pixels; taller than a result row, Raycast-style.";
    };

    radius = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 16;
      description = "Panel corner radius in pixels; 16 matches the old rofi theme.";
    };

    accent = lib.mkOption {
      type = lib.types.str;
      default = "#7fd6c2";
      example = "#8fb8f0";
      description = ''
        Accent colour for the currently-active element: the highlighted
        result row and the active filter pill. Alternates that read well
        against the Tokyonight background above: `#8fb8f0` (blue), `#e0b083`
        (amber), `#c9a8f0` (violet).
      '';
    };

    terminal = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe config.programs.kitty.package;
      defaultText = lib.literalExpression "lib.getExe config.programs.kitty.package";
      description = ''
        Terminal used for desktop entries marked `Terminal=true`, and by the
        "Open in terminal" action. Follows `programs.kitty.package` rather than
        naming a binary, so switching terminals is one option away and the
        launcher cannot end up pointing at something that is not installed.
      '';
    };

    fileManager = lib.mkOption {
      type = lib.types.str;
      default = "xdg-open";
      description = ''
        Command the "Reveal in file manager" action runs on a directory.
        `xdg-open` resolves through the desktop's own `inode/directory`
        association, which is why it is the default rather than a specific
        file manager.
      '';
    };

    disabledProviders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "files" ];
      description = "Provider ids to leave out entirely.";
    };

    clipboardHistory = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the clipboard-history watcher. Wayland offers no way to poll the
        clipboard, so history needs a long-lived process holding a data offer;
        without this the `c ` provider has nothing to show.
      '';
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
              description = "Text pasted into the focused window.";
            };
            keyword = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Accessory label shown on the row.";
            };
          };
        }
      );
      default = [ ];
      description = "Expandable text snippets.";
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
              description = ''
                URL, or shell command when `command` is set. `{query}` is
                replaced with whatever is typed past the name, percent-encoded
                for a URL, shell-quoted for a command.
              '';
            };
            command = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Treat the target as a shell command rather than a URL.";
            };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Icon file; SVG and PNG render.";
            };
          };
        }
      );
      default = [ ];
      description = "Parameterised links and commands.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      beamenuPkg
      recordToggle
      # Runtime dependencies of the providers and of dispatch. Each is reached
      # by name from Rust rather than by store path, because they are all
      # things a user would also invoke by hand.
      pkgs.wl-clipboard # clipboard history capture, and Copy actions
      pkgs.wtype # Paste actions (snippets, emoji, clipboard)
      pkgs.fd # the `f ` file provider
      pkgs.hyprshot # Screenshot commands, replacing hyprtile-shotter
      pkgs.wl-screenrec # screen recording, replacing hyprtile-screener
    ];

    xdg.configFile = {
      "beamenu/config.json".text = builtins.toJSON configJson;
      "beamenu/snippets.json".text = builtins.toJSON cfg.snippets;
      "beamenu/quicklinks.json".text = builtins.toJSON cfg.quicklinks;
    };

    # Script commands are discovered at query time, so the directory has to
    # exist even when empty or the provider has nothing to scan.
    home.file.".config/beamenu/scripts/.keep".text = "";

    systemd.user.services.beamenu-clipboard = lib.mkIf cfg.clipboardHistory {
      Unit = {
        Description = "beamenu clipboard history watcher";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        # wl-paste needs a Wayland display; without one the unit would
        # restart-loop for the whole session.
        ConditionEnvironment = [ "WAYLAND_DISPLAY" ];
      };
      Service = {
        ExecStart = "${lib.getExe beamenuPkg} --daemon";
        Restart = "on-failure";
        RestartSec = 3;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
