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
  beamenuCanvasPkg,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.beamenu;

  # The system palette — rust/palette.json is the single source of truth for
  # neutrals, fonts and the beamenu metrics. The Rust side compiles the same
  # file in (rust/beamenu/src/palette.rs, rust/beamenu-canvas/src/palette.rs);
  # this module is the configured path, the Rust Default impls the fallback.
  palette = builtins.fromJSON (builtins.readFile ../../rust/palette.json);
  inherit (palette) colors alpha;

  # bemenu wants #RRGGBBAA, so alpha is applied here at the seam; base values
  # stay 6-digit in the palette file. selected_background and heading derive
  # from cfg.accent, so programs.beamenu.accent moves every accent surface —
  # highlighted row, heading tint and the canvas accent — not just the
  # highlighted row. Text drawn on the accent fill is bgDarker (dark on
  # light-accent, as the launcher always had).
  theme = {
    background = colors.bg + alpha.panel;
    foreground = colors.fg + alpha.opaque;
    muted = colors.muted + alpha.opaque;
    selected_background = cfg.accent + alpha.opaque;
    selected_foreground = colors.bgDarker + alpha.opaque;
    border = colors.border + alpha.opaque;
    heading = cfg.accent + alpha.heading;
    font = "${palette.fonts.ui} ${toString palette.fonts.size}";
    accent = cfg.accent;
    # beamenu-canvas reads theme.canvas (rust/beamenu-canvas/src/config.rs);
    # this key was never emitted before, so the sidecar always rendered its
    # compiled-in defaults. Field names are CanvasTheme's serde names; values
    # stay 6-digit because the canvas applies alpha in CSS itself. border is
    # the hairline (selection slot), border_strong the brighter border slot.
    canvas = {
      font_ui = palette.fonts.canvasUi;
      font_mono = palette.fonts.canvasMono;
      bg = colors.bg;
      panel_gradient_start = colors.bgDark;
      panel_gradient_end = colors.bg;
      border = colors.selection;
      border_strong = colors.border;
      text = colors.fg;
      muted = colors.muted;
      accent = cfg.accent;
    };
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
      default = palette.beamenu.lines;
      description = "Result rows shown at once; the panel height follows from this.";
    };

    widthFactor = lib.mkOption {
      type = lib.types.float;
      default = palette.beamenu.widthFactor;
      description = ''
        Fraction of the output width the panel occupies. bemenu has no
        absolute width, only this factor, so the default is rofi's 720px
        expressed against a 1920px output.
      '';
    };

    iconSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = palette.beamenu.iconSize;
      description = "Row icon edge length in pixels.";
    };

    lineHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = palette.beamenu.lineHeight;
      description = "Result row height in pixels.";
    };

    searchHeight = lib.mkOption {
      type = lib.types.ints.positive;
      default = palette.beamenu.searchHeight;
      description = "Search row height in pixels; taller than a result row, Raycast-style.";
    };

    radius = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = palette.beamenu.radius;
      description = "Panel corner radius in pixels; 16 matches the old rofi theme.";
    };

    accent = lib.mkOption {
      type = lib.types.str;
      default = palette.accentFallback;
      example = "#7fd6c2";
      description = ''
        Accent colour for every accent surface: the highlighted result row,
        the active filter pill, the heading tint and the canvas accent —
        `selected_background`, `heading` and `theme.canvas.accent` all
        derive from it. Its own text is always the palette's darkest
        neutral, so alternates should stay light: `#7fd6c2` (teal),
        `#e0b083` (amber), `#c9a8f0` (violet).
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

    plugins = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            title = lib.mkOption {
              type = lib.types.str;
              description = "Section heading this plugin's rows are grouped under, and its pill label.";
            };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Icon file shared by every row this plugin contributes; SVG and PNG render.";
            };
            keyword = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Prefix that reaches this plugin, narrowing the root list down
                to just its commands. Omitted means ambient: every command is
                fuzzy-ranked into the root list instead, like a quicklink.
                Matched at a word boundary: a trailing space is appended
                automatically when not already present, so `"cl"` reaches
                this plugin on `"cl ask"` but not on `"clone"`.
              '';
            };
            commands = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    id = lib.mkOption {
                      type = lib.types.str;
                      description = ''
                        Stable identity within the plugin. Reaches this
                        command via `beamenu --command`-style argv when
                        `mode = "view"`: `beamenu-canvas --manifest … --command <id>`.
                      '';
                    };
                    title = lib.mkOption {
                      type = lib.types.str;
                      description = "Row title.";
                    };
                    description = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Row subtitle.";
                    };
                    mode = lib.mkOption {
                      type = lib.types.enum [
                        "exec"
                        "terminal"
                        "copy"
                        "view"
                      ];
                      description = ''
                        What activating the row does: `exec` spawns `exec`
                        detached; `terminal` wraps it in the configured
                        terminal; `copy` copies the `{query}`-substituted
                        `exec`, joined into one shell command, onto the
                        clipboard; `view` opens the `beamenu-canvas` sidecar.
                      '';
                    };
                    ui = lib.mkOption {
                      type = lib.types.enum [
                        "log"
                        "rpc"
                      ];
                      default = "log";
                      description = "Sidecar renderer used when `mode = \"view\"`.";
                    };
                    exec = lib.mkOption {
                      type = lib.types.listOf lib.types.str;
                      description = ''
                        Argv. `{query}` in any element is replaced with
                        whatever was typed past the plugin's keyword (or the
                        whole query, for an ambient plugin) before this runs.
                      '';
                    };
                  };
                }
              );
              default = [ ];
              description = "Commands this plugin exposes as rows.";
            };
          };
        }
      );
      default = { };
      description = ''
        JSON plugin manifests. Each attribute becomes its own provider — own
        section heading, own pill, own optional keyword — rendered to
        `beamenu/plugins/<name>.json`, where `<name>` is the attribute name
        and doubles as the manifest's `name` field and the provider id
        `disabledProviders` matches against.
      '';
      example = lib.literalExpression ''
        {
          claude = {
            title = "Claude Code";
            keyword = "cl";
            commands = [
              {
                id = "ask";
                title = "Ask Claude";
                mode = "view";
                exec = [ "bash" "-lc" "claude --print {query}" ];
              }
            ];
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      beamenuPkg
      # The WebKitGTK sidecar `beamenu` spawns for a plugin's `view`
      # command (rust/beamenu-canvas) — a separate binary/process, so it
      # needs its own store path on PATH the same way beamenuPkg does.
      beamenuCanvasPkg
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
    }
    // lib.mapAttrs' (
      name: plugin:
      # The attribute name is the manifest's `name` field too, so the file
      # a plugin ships as and the provider id `disabledProviders` names are
      # never able to drift apart from each other.
      lib.nameValuePair "beamenu/plugins/${name}.json" {
        text = builtins.toJSON (plugin // { inherit name; });
      }
    ) cfg.plugins;

    # Script commands and plugin manifests are both discovered at query time,
    # so their directories have to exist even when empty or the respective
    # provider has nothing to scan.
    home.file.".config/beamenu/scripts/.keep".text = "";
    home.file.".config/beamenu/plugins/.keep".text = "";

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
