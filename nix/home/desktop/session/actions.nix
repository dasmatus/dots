# Every keybound action and every startup action in the desktop session, as
# pure metadata. It exists so a second tiling WM can be added later by
# consuming this table instead of copying command strings out of
# `nix/home/desktop/hyprland.nix`.
#
# This is a plain data file, not a home-manager module: `import ./actions.nix`
# returns a list, full stop, with no arguments to fill in. That is load-bearing
# rather than stylistic. `nix/home/desktop/keybinds.nix` is imported the same
# argument-free way from two places, one of which (`flake/packages.nix`) has
# no evaluated home-manager config to draw arguments from, and
# `nix/home/desktop/quickshell/tree.nix` runs a strict `builtins.toJSON` over the
# result — a lambda, a `pkgs` reference, or a store path anywhere in this file
# would break both. Commands are attached later, in `nix/home/desktop/session/default.nix`,
# keyed by `name`; that is also why this table has no `command` field of its
# own.
#
# Every entry carries all nine attributes below, never omitted, so no
# consumer ever needs an `or` default:
#
#   name       unique identifier and the only join key: task 2's
#              `default.nix` attaches a command by `name`, never by
#              `dispatch`. Kebab-case for daemon/startup/app/action entries.
#              For `kind = "dispatch"` it is usually the `dispatch` value
#              itself, but not always: several `name`s can share one
#              `dispatch`, because `name` must stay unique while `dispatch`
#              only has to be unique per distinct action. `focus.left` and
#              `focus.left-arrow` are two such `name`s, both carrying
#              `dispatch = "focus.left"` — the HJKL and arrow-key rows fire
#              the same dispatcher from a different key. Task 4's bind
#              generator must therefore key its dispatcher lookup off
#              `dispatch`, never off `name`.
#   mods       modifier list, in the order written below; `[ ]` for
#              daemon/startup entries and for keys with no modifier.
#   key        the key itself, no modifiers; `null` for daemon/startup
#              entries, which have no key at all.
#   desc       human sentence for the cheatsheet.
#   category   cheatsheet group. One of: launchers, window, focus,
#              workspaces, special, session, touchpad, media, kitty.
#              Daemon/startup entries are filed under `session`, since they
#              are session-lifecycle actions rather than keybinds.
#   kind       one of:
#                daemon  — long-running, started with the session, no key.
#                startup — runs once at session start and exits, no key.
#                app     — a GUI app launched by a key, repeat-launchable.
#                action  — a short command fired by a key (IPC calls,
#                          reload, lock).
#                dispatch — no command at all; the WM handles it natively.
#   dispatch   abstract dispatcher name (dotted lowercase, WM-agnostic),
#              non-null only for `kind = "dispatch"`. A future
#              `nix/home/sway.nix` maps the same name to `swaymsg` instead
#              of Hyprland's `hl.dsp.*` call.
#   repeating  true only for keys that fire while held.
#   mouse      true only for mouse binds.
#
# Transcribed from `nix/home/desktop/hyprland.nix`: the five `hl.exec_cmd` calls in
# the `hyprland.start` handler (lines 63-81 at transcription time) become the
# `daemon`/`startup` entries below; every entry in the `bind` list (lines
# 375-905 at transcription time) becomes one row here, `app`/`action` for the
# nineteen that call `hl.dsp.exec_cmd`, `dispatch` for the rest. Nothing is
# left out: task 4 renders every one of these back into a Hyprland bind.
#
# One correction versus the plan this table was commissioned against: that
# plan counted four `repeating = true` binds (volume/brightness). The source
# carries eight — the four keyboard window-resize binds (SUPER+ALT+H/J/K/L)
# also carry `{ repeating = true; }` in `hyprland.nix`, grouped under the same
# "repeating binds (was binde)" comment as volume/brightness. This table
# follows the source.
let
  entries = [
    # awww-daemon must be up before anything that talks to it over its IPC
    # socket (the shell's Picker.qml/Rotation.qml, now that wallpaper-tui is
    # gone); awww img blocks briefly and retries, so the ordering matters at
    # most for that first call, not for this row itself.
    {
      name = "awww-daemon";
      mods = [ ];
      key = null;
      desc = "Wallpaper daemon (awww)";
      category = "session";
      kind = "daemon";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The bar's network pill reports state; nm-applet's tray icon is what
    # actually offers a menu to switch networks, so it stays until the shell
    # grows that.
    {
      name = "nm-applet";
      mods = [ ];
      key = null;
      desc = "Network manager tray applet";
      category = "session";
      kind = "daemon";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # launchers
    {
      name = "terminal";
      mods = [ "SUPER" ];
      key = "Return";
      desc = "Terminal (kitty)";
      category = "launchers";
      kind = "app";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The launcher is a Quickshell surface the shell already has open, so this
    # toggles it rather than spawning anything. beamenu ran a fresh binary per
    # keypress and got away with it because layer-shell plus cairo starts fast;
    # not starting at all is faster still.
    #
    # The IPC function is `toggle` and not `show` for a reason worth knowing:
    # `qs ipc call launcher show` is swallowed by the `qs ipc show` subcommand,
    # which prints the handler listing and exits successfully without calling
    # anything.
    #
    # One bind, not three. SUPER+D and SUPER+SHIFT+E both ran plain `beamenu`
    # (the second one's comment claimed a pre-seeded query, which nothing ever
    # seeded), and SUPER+comma skipped the launcher to open the settings
    # plugin's canvas view directly. Everything they reached is inside the
    # panel.
    {
      name = "launcher-toggle";
      mods = [ "SUPER" ];
      key = "Space";
      desc = "Launcher — apps, windows, system, files, clipboard";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The shell's own file manager (nix/home/desktop/quickshell/qml/files), reached
    # by IPC into the already-running shell rather than by spawning
    # anything. This bind ran `nautilus` until the shell grew a file manager
    # of its own. `kind` reads "action" and not "app" for the same reason
    # every other `qs ipc call … toggle` row here does: the command returns
    # immediately, so its unit wants `Type = "oneshot"`, which
    # nix/home/desktop/session/default.nix grants to `action` and not to `app`.
    {
      name = "file-manager";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "F";
      desc = "File manager";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    {
      name = "notes";
      mods = [ "SUPER" ];
      key = "O";
      desc = "Obsidian";
      category = "launchers";
      kind = "app";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # Zed editor — the GUI code editor that replaces VSCodium. The nixpkgs
    # `zed-editor` package installs its binary as `zeditor` (its
    # meta.mainProgram), not `zed`, so the bare command name here is that
    # binary. programs.zed-editor (nix/home/apps/zed.nix) puts it on PATH.
    {
      name = "editor";
      mods = [ "SUPER" ];
      key = "Z";
      desc = "Zed editor";
      category = "launchers";
      kind = "app";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The keybind cheatsheet (nix/home/desktop/keybinds.nix). A plain toggle now: the
    # once-per-install sentinel and the --force flag that skipped it went with
    # eww.
    {
      name = "cheatsheet-toggle";
      mods = [ "SUPER" ];
      key = "slash";
      desc = "Show this keybind cheatsheet";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The settings form (rust/settings-global, rendered by the shell). This
    # bind was retired when the settings menu became a beamenu plugin
    # answering the `set ` keyword, on the grounds that one door into the
    # launcher beat three. That keyword went with beamenu, and a form the
    # shell draws itself has no launcher row to hide behind, so the direct
    # bind comes back.
    {
      name = "settings-toggle";
      mods = [ "SUPER" ];
      key = "comma";
      desc = "Settings (git identity, hostname, AI tools)";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The wallpaper picker (nix/home/desktop/quickshell/qml/wallpaper/Picker.qml).
    # Toggled the same way the launcher and settings form are: it is already
    # open inside the shell process, so there is nothing to spawn.
    {
      name = "wallpaper-toggle";
      mods = [ "SUPER" ];
      key = "W";
      desc = "Wallpaper picker";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The monitor arrange surface (nix/home/desktop/quickshell/qml/monitors/
    # Arrange.qml), hyprmon.nix's old "Monitors" desktop entry replaced by a
    # direct bind — one door in, like the settings form and the wallpaper
    # picker above.
    {
      name = "arrange-toggle";
      mods = [ "SUPER" ];
      key = "M";
      desc = "Arrange monitors (drag to reposition)";
      category = "launchers";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # window ops
    {
      name = "window.close";
      mods = [ "SUPER" ];
      key = "Q";
      desc = "Close window";
      category = "window";
      kind = "dispatch";
      dispatch = "window.close";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.float-toggle";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Space";
      desc = "Toggle floating";
      category = "window";
      kind = "dispatch";
      dispatch = "window.float-toggle";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.fullscreen";
      mods = [ "SUPER" ];
      key = "F";
      desc = "Fullscreen";
      category = "window";
      kind = "dispatch";
      dispatch = "window.fullscreen";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.pseudo";
      mods = [ "SUPER" ];
      key = "P";
      desc = "Pseudo-tiling";
      category = "window";
      kind = "dispatch";
      dispatch = "window.pseudo";
      repeating = false;
      mouse = false;
    }

    # scratch special workspace
    {
      name = "workspace.toggle-scratch";
      mods = [ "SUPER" ];
      key = "minus";
      desc = "Toggle scratch workspace";
      category = "special";
      kind = "dispatch";
      dispatch = "workspace.toggle-scratch";
      repeating = false;
      mouse = false;
    }
    {
      name = "workspace.move-scratch";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "minus";
      desc = "Move window to scratch workspace";
      category = "special";
      kind = "dispatch";
      dispatch = "workspace.move-scratch";
      repeating = false;
      mouse = false;
    }

    # focus directional (HJKL + arrows)
    {
      name = "focus.left";
      mods = [ "SUPER" ];
      key = "H";
      desc = "Focus left";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.left";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.right";
      mods = [ "SUPER" ];
      key = "L";
      desc = "Focus right";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.right";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.up";
      mods = [ "SUPER" ];
      key = "K";
      desc = "Focus up";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.up";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.down";
      mods = [ "SUPER" ];
      key = "J";
      desc = "Focus down";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.down";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.left-arrow";
      mods = [ "SUPER" ];
      key = "Left";
      desc = "Focus left (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.left";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.right-arrow";
      mods = [ "SUPER" ];
      key = "Right";
      desc = "Focus right (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.right";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.up-arrow";
      mods = [ "SUPER" ];
      key = "Up";
      desc = "Focus up (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.up";
      repeating = false;
      mouse = false;
    }
    {
      name = "focus.down-arrow";
      mods = [ "SUPER" ];
      key = "Down";
      desc = "Focus down (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "focus.down";
      repeating = false;
      mouse = false;
    }

    # move window directional (SHIFT + HJKL/arrows)
    {
      name = "window.move-left";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "H";
      desc = "Move window left";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-left";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-right";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "L";
      desc = "Move window right";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-right";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-up";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "K";
      desc = "Move window up";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-up";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-down";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "J";
      desc = "Move window down";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-down";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-left-arrow";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Left";
      desc = "Move window left (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-left";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-right-arrow";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Right";
      desc = "Move window right (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-right";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-up-arrow";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Up";
      desc = "Move window up (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-up";
      repeating = false;
      mouse = false;
    }
    {
      name = "window.move-down-arrow";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Down";
      desc = "Move window down (arrow key)";
      category = "focus";
      kind = "dispatch";
      dispatch = "window.move-down";
      repeating = false;
      mouse = false;
    }

  ]
  # workspace 1-10 (key 0 → workspace 10)
  ++ builtins.genList (
    i:
    let
      n = i + 1;
    in
    {
      name = "workspace.focus-${toString n}";
      mods = [ "SUPER" ];
      key = if n == 10 then "0" else toString n;
      desc = "Focus workspace ${toString n}";
      category = "workspaces";
      kind = "dispatch";
      dispatch = "workspace.focus-${toString n}";
      repeating = false;
      mouse = false;
    }
  ) 10
  # move window to workspace 1-10
  ++ builtins.genList (
    i:
    let
      n = i + 1;
    in
    {
      name = "workspace.move-${toString n}";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = if n == 10 then "0" else toString n;
      desc = "Move window to workspace ${toString n}";
      category = "workspaces";
      kind = "dispatch";
      dispatch = "workspace.move-${toString n}";
      repeating = false;
      mouse = false;
    }
  ) 10
  ++ [
    # mouse-wheel workspace cycling
    {
      name = "workspace.next";
      mods = [ "SUPER" ];
      key = "mouse_down";
      desc = "Focus next workspace";
      category = "workspaces";
      kind = "dispatch";
      dispatch = "workspace.next";
      repeating = false;
      mouse = false;
    }
    {
      name = "workspace.prev";
      mods = [ "SUPER" ];
      key = "mouse_up";
      desc = "Focus previous workspace";
      category = "workspaces";
      kind = "dispatch";
      dispatch = "workspace.prev";
      repeating = false;
      mouse = false;
    }

    # magic special workspace
    {
      name = "workspace.toggle-magic";
      mods = [ "SUPER" ];
      key = "S";
      desc = "Toggle magic workspace";
      category = "special";
      kind = "dispatch";
      dispatch = "workspace.toggle-magic";
      repeating = false;
      mouse = false;
    }
    {
      name = "workspace.move-magic";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "S";
      desc = "Move window to magic workspace";
      category = "special";
      kind = "dispatch";
      dispatch = "workspace.move-magic";
      repeating = false;
      mouse = false;
    }

    # lock + session
    {
      name = "lock";
      mods = [
        "SUPER"
        "ALT"
      ];
      key = "L";
      desc = "Lock screen (hyprlock)";
      category = "session";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    # The power menu had its own SUPER+SHIFT+E bind running plain `beamenu`,
    # the identical command SUPER+D ran, on the claim that the query was
    # pre-seeded to the session commands. Nothing seeded it. Those commands
    # live under the System pill, one Tab from opening SUPER+Space.
    {
      name = "reload";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "C";
      desc = "Reload Hyprland config";
      category = "session";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # Print (no modifier) is the screenshot key; SUPER+SHIFT+S stays reserved
    # for the magic special workspace (was double-bound in hyprlang).
    # SUPER+Print selects a region, SUPER+SHIFT+Print picks a window — the one
    # capture grim + slurp could not do, and the reason all three moved to
    # hyprshot. Each saves into the xdg-user-dir PICTURES folder, copies the
    # image to the clipboard and raises its own notification. The commands
    # themselves live in nix/home/desktop/hyprland.nix, since hyprshot speaks
    # Hyprland's own IPC. All three are also reachable from the launcher.
    #
    # `screenshot-output` says "focused output", not "whole screen": hyprshot
    # grabs one monitor, where the grim call it replaces composited every
    # output into a single image.
    {
      name = "screenshot-output";
      mods = [ ];
      key = "Print";
      desc = "Screenshot (focused output)";
      category = "session";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    {
      name = "screenshot-region";
      mods = [ "SUPER" ];
      key = "Print";
      desc = "Screenshot (select region)";
      category = "session";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    {
      name = "screenshot-window";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "Print";
      desc = "Screenshot (pick a window)";
      category = "session";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # These call the shell's OSD rather than wpctl directly, so the change is
    # drawn as it is made. That is the whole point: a mute toggle that shows
    # nothing leaves you tapping the key to find out which way it went. The
    # shell sets the Pipewire node itself instead of spawning wpctl, which
    # dots-osd paid for twice per keypress. See
    # nix/home/desktop/quickshell/qml/osd/Osd.qml.
    {
      name = "volume-mute";
      mods = [ ];
      key = "XF86AudioMute";
      desc = "Mute audio output (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }
    {
      name = "mic-mute";
      mods = [ ];
      key = "XF86AudioMicMute";
      desc = "Mute microphone (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # Touchpad off and on, for typing on a laptop with the heel of a hand in
    # the way. Hyprland cannot be asked whether a device is enabled, so the
    # shell remembers it for the life of the process — which ends at logout,
    # exactly when Hyprland forgets the setting too.
    {
      name = "touchpad-toggle";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "T";
      desc = "Touchpad on / off";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # Privacy switch: mute the microphone, and name anything holding the
    # camera open so "privacy on" is never read as "the camera is off".
    {
      name = "privacy-toggle";
      mods = [
        "SUPER"
        "SHIFT"
      ];
      key = "P";
      desc = "Privacy: mute the microphone";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = false;
      mouse = false;
    }

    # keyboard window resize, repeating while held (ALT + HJKL)
    {
      name = "window.resize-left";
      mods = [
        "SUPER"
        "ALT"
      ];
      key = "H";
      desc = "Resize window narrower";
      category = "window";
      kind = "dispatch";
      dispatch = "window.resize-left";
      repeating = true;
      mouse = false;
    }
    {
      name = "window.resize-right";
      mods = [
        "SUPER"
        "ALT"
      ];
      key = "L";
      desc = "Resize window wider";
      category = "window";
      kind = "dispatch";
      dispatch = "window.resize-right";
      repeating = true;
      mouse = false;
    }
    {
      name = "window.resize-up";
      mods = [
        "SUPER"
        "ALT"
      ];
      key = "K";
      desc = "Resize window shorter";
      category = "window";
      kind = "dispatch";
      dispatch = "window.resize-up";
      repeating = true;
      mouse = false;
    }
    {
      name = "window.resize-down";
      mods = [
        "SUPER"
        "ALT"
      ];
      key = "J";
      desc = "Resize window taller";
      category = "window";
      kind = "dispatch";
      dispatch = "window.resize-down";
      repeating = true;
      mouse = false;
    }

    # Volume and brightness, still ±5% and still repeating while held — but
    # through the shell, which moves the Pipewire node or runs brightnessctl
    # and then draws the resulting level as a progress bar. The 1.5 boost
    # ceiling on the way up lives there too
    # (nix/home/desktop/quickshell/qml/osd/Osd.qml); it is not lost here.
    {
      name = "volume-up";
      mods = [ ];
      key = "XF86AudioRaiseVolume";
      desc = "Volume up 5% (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = true;
      mouse = false;
    }
    {
      name = "volume-down";
      mods = [ ];
      key = "XF86AudioLowerVolume";
      desc = "Volume down 5% (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = true;
      mouse = false;
    }
    {
      name = "brightness-up";
      mods = [ ];
      key = "XF86MonBrightnessUp";
      desc = "Brightness up 5% (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = true;
      mouse = false;
    }
    {
      name = "brightness-down";
      mods = [ ];
      key = "XF86MonBrightnessDown";
      desc = "Brightness down 5% (shows an OSD)";
      category = "media";
      kind = "action";
      dispatch = null;
      repeating = true;
      mouse = false;
    }

    # mouse binds: movewindow → window.drag, resizewindow → window.resize
    # (mouse-drag form, no args — distinct from the keyboard window.resize-*
    # dispatchers above, which carry a direction and a fixed step).
    {
      name = "window.drag";
      mods = [ "SUPER" ];
      key = "mouse:272";
      desc = "Move window (mouse drag)";
      category = "session";
      kind = "dispatch";
      dispatch = "window.drag";
      repeating = false;
      mouse = true;
    }
    {
      name = "window.resize";
      mods = [ "SUPER" ];
      key = "mouse:273";
      desc = "Resize window (mouse drag)";
      category = "session";
      kind = "dispatch";
      dispatch = "window.resize";
      repeating = false;
      mouse = true;
    }
  ];

  # `name` is the only join key (see the header above): `default.nix`'s
  # `lib.listToAttrs` and `keybinds.nix`'s `findAction` both resolve it by
  # first match (`builtins.head`), so a duplicate `name` would not fail
  # loudly at either call site — it would silently pick one of the two rows
  # and drop the other. Checked once, here, in the file both of those
  # consumers import (`session/default.nix` via `import ./actions.nix`,
  # `keybinds.nix` via `import ./session/actions.nix`), so both inherit the
  # guarantee for free instead of each needing their own copy of it — an
  # assertion living in `session/default.nix`'s own `config.assertions`
  # would not fire for `keybinds.nix`'s standalone, module-free evaluation
  # (flake/packages.nix, nix/home/desktop/quickshell/tree.nix), and one living only
  # in `keybinds.nix` would not fire for `session/default.nix` either, since
  # neither file is the other's consumer.
  groups = builtins.groupBy (a: a.name) entries;
  duplicateNames = builtins.filter (name: builtins.length groups.${name} > 1) (
    builtins.attrNames groups
  );
in
if duplicateNames != [ ] then
  throw "nix/home/desktop/session/actions.nix: duplicate `name` value(s) in the action table: ${builtins.concatStringsSep ", " duplicateNames}"
else
  entries
