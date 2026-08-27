# Quickshell is the desktop shell. Bar, notifications, OSD, launcher and the
# settings form all live in one QML tree (nix/home/quickshell/qml) instead of
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
  ...
}:
let
  cfg = config.programs.dots-shell;

  tree = import ./tree.nix {
    inherit pkgs;
    inherit (cfg) quicklinks snippets;
    keybinds = import ../keybinds.nix;
    stateHome = config.xdg.stateHome;
  };
in
{
  options.programs.dots-shell = {
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
      # provider shells out to fd. Both were beamenu's dependencies and move
      # here with the providers that use them.
      pkgs.wl-clipboard
      pkgs.fd
    ];

    # Lands at $XDG_CONFIG_HOME/quickshell, which is where a bare `qs` looks
    # for shell.qml, so the compositor's exec line needs no --path.
    xdg.configFile."quickshell".source = tree;

    # The shell runs as a unit rather than as a child of the compositor.
    # `hyprland.start` fires once at compositor boot (nix/home/hyprland.nix),
    # so anything launched from there stays dead until the next login — a
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
        After = [ "graphical-session-pre.target" ];
        # The bar's workspace and window pills read Hyprland's socket, so a
        # non-Hyprland session has no shell to run. Same gate as hyprmon.
        ConditionPathExists = [ "%t/hypr" ];
        X-Restart-Triggers = [ "${tree}" ];
      };
      Service = {
        ExecStart = lib.getExe pkgs.quickshell;
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
