# Home-manager Hyprland compositor config. Imported by
# nix/home/profiles/session.nix when dots.desktop.environment == "hyprland".
# Shares GTK/Qt/dconf/cursor with the other DEs through ./common.nix.
{
  config,
  pkgs,
  lib,
  settings,
  ...
}:
let
  lua = lib.generators.mkLuaInline;

  cfg = config.dots.session;
  actions = import ./session/actions.nix;
  keyedActions = builtins.filter (a: a.key != null) actions;

  # `hyprctl`'s `meta.mainProgram` is "Hyprland" (capitalised; `hyprctl` is a
  # second binary in the same package, same as quickshell's `qs` in
  # nix/home/desktop/session/default.nix). Verified against the pinned nixpkgs,
  # hence `getExe'` rather than `getExe`.
  hyprctl = lib.getExe' pkgs.hyprland "hyprctl";

  # hyprshot picks its save folder from $HYPRSHOT_DIR, then $XDG_PICTURES_DIR,
  # then `xdg-user-dir PICTURES`, and only if that binary is on $PATH, which
  # nixpkgs' wrapper does not arrange (it prefixes hyprland, jq, grim, slurp,
  # wl-clipboard, libnotify and hyprpicker, not xdg-user-dirs). Its last
  # resort is $HOME, so an unresolved lookup drops screenshots in the home
  # directory rather than in the pictures folder. A unit's ExecStart is not a
  # shell, so the lookup cannot be inlined there; this resolves it by absolute
  # store path and hands the answer to `-o`, which overrides every lookup
  # hyprshot would otherwise do. hyprshot creates the folder itself.
  #
  # `|| true` is not laziness. hyprshot's exit status is whatever its final
  # `pkill hyprpicker` returned (its watcher ends `pkill hyprpicker; exit`),
  # so it says nothing about whether the capture worked and is 1 on every run
  # that did not freeze the screen. Letting that through would mark a
  # perfectly good screenshot's unit failed on every Print tap. hyprshot's own
  # notification is the success signal.
  hyprshot = pkgs.writeShellScript "dots-hyprshot" ''
    set -euo pipefail
    pictures="$(${lib.getExe' pkgs.xdg-user-dirs "xdg-user-dir"} PICTURES 2> /dev/null || true)"
    ${lib.getExe pkgs.hyprshot} -o "''${pictures:-$HOME/Pictures}" "$@" || true
  '';

  # The dispatcher map: `dispatch` (actions.nix) → the Lua expression that
  # invokes it. This is the WM-specific half of this file, the only part
  # that knows Hyprland's own `hl.dsp.*` spelling, and is exactly what a
  # future nix/home/sway.nix replaces with a map onto `swaymsg`. Keyed off
  # `dispatch`, never off `name`: several `name`s (e.g. `focus.left` and
  # `focus.left-arrow`) share one `dispatch` value, and looking this up by
  # `name` instead would either miss rows or duplicate dispatchers.
  dispatchMap = {
    "window.close" = lua "hl.dsp.window.close()";
    "window.float-toggle" = lua ''hl.dsp.window.float({ action = "toggle" })'';
    "window.fullscreen" = lua "hl.dsp.window.fullscreen()";
    "window.pseudo" = lua "hl.dsp.window.pseudo()";

    "workspace.toggle-scratch" = lua ''hl.dsp.workspace.toggle_special("scratch")'';
    "workspace.move-scratch" = lua ''hl.dsp.window.move({ workspace = "special:scratch" })'';
    "workspace.toggle-magic" = lua ''hl.dsp.workspace.toggle_special("magic")'';
    "workspace.move-magic" = lua ''hl.dsp.window.move({ workspace = "special:magic" })'';
    "workspace.next" = lua ''hl.dsp.focus({ workspace = "e+1" })'';
    "workspace.prev" = lua ''hl.dsp.focus({ workspace = "e-1" })'';

    "focus.left" = lua ''hl.dsp.focus({ direction = "l" })'';
    "focus.right" = lua ''hl.dsp.focus({ direction = "r" })'';
    "focus.up" = lua ''hl.dsp.focus({ direction = "u" })'';
    "focus.down" = lua ''hl.dsp.focus({ direction = "d" })'';

    "window.move-left" = lua ''hl.dsp.window.move({ direction = "l" })'';
    "window.move-right" = lua ''hl.dsp.window.move({ direction = "r" })'';
    "window.move-up" = lua ''hl.dsp.window.move({ direction = "u" })'';
    "window.move-down" = lua ''hl.dsp.window.move({ direction = "d" })'';

    "window.resize-left" = lua "hl.dsp.window.resize({ x = -40, y = 0, relative = true })";
    "window.resize-right" = lua "hl.dsp.window.resize({ x = 40, y = 0, relative = true })";
    "window.resize-up" = lua "hl.dsp.window.resize({ x = 0, y = -40, relative = true })";
    "window.resize-down" = lua "hl.dsp.window.resize({ x = 0, y = 40, relative = true })";

    "window.drag" = lua "hl.dsp.window.drag()";
    "window.resize" = lua "hl.dsp.window.resize()";
  }
  # workspace 1-10 dispatchers, focus and move: generated rather than
  # spelled out twenty times over, the same way actions.nix itself
  # generates the rows that reference them.
  // lib.listToAttrs (
    map (
      n:
      lib.nameValuePair "workspace.focus-${toString n}" (
        lua "hl.dsp.focus({ workspace = ${toString n} })"
      )
    ) (lib.range 1 10)
  )
  // lib.listToAttrs (
    map (
      n:
      lib.nameValuePair "workspace.move-${toString n}" (
        lua "hl.dsp.window.move({ workspace = ${toString n} })"
      )
    ) (lib.range 1 10)
  );

  # Key rendering. `mods = [ ]` passes the key straight through as a plain
  # Nix string (`"Print"`, `"XF86AudioMute"`), which HM emits as a quoted lua
  # string. Every other row's `mods` starts with "SUPER": `mod` (the local
  # below) is concatenated with the remaining modifiers and the key, e.g.
  # `[ "SUPER" "SHIFT" ]` with key `F` becomes `mod .. " + SHIFT + F"`.
  mkKey =
    a:
    if a.mods == [ ] then
      a.key
    else if lib.head a.mods == "SUPER" then
      lua ''mod .. " + ${lib.concatStringsSep " + " (lib.tail a.mods ++ [ a.key ])}"''
    else
      throw "nix/home/desktop/hyprland.nix: mkKey does not know how to render a mods list not starting with SUPER, from action `${a.name}`";

  # Dispatcher rendering. `kind = "dispatch"` rows have no command at all,
  # look their `dispatch` up in `dispatchMap`. Every other keyed row
  # (`app`/`action`) has a command in `config.dots.session.commands`, keyed
  # by `name`, run through `hl.dsp.exec_cmd`. `builtins.toJSON` escapes the
  # literal double quotes some commands carry (e.g. the `$RANDOM`-suffixed
  # unit name) into a lua string literal that Lua parses the same way JSON
  # does; this is ASCII-only input, so `toJSON`'s `\uXXXX` escaping of
  # non-ASCII text never fires here. Widening the commands to non-ASCII
  # would need a second look at this.
  mkDispatch =
    a:
    if a.kind == "dispatch" then
      dispatchMap.${a.dispatch}
        or (throw "nix/home/desktop/hyprland.nix: no Lua dispatcher registered for dispatch `${a.dispatch}`, from action `${a.name}`")
    else
      lua "hl.dsp.exec_cmd(${builtins.toJSON cfg.commands.${a.name}})";

  # One `hl.bind` per keyed row: key, dispatcher, then the flags the row
  # carries. `repeating` and `mouse` are never both true for the same row.
  mkBind = a: {
    _args = [
      (mkKey a)
      (mkDispatch a)
    ]
    ++ lib.optional a.repeating { repeating = true; }
    ++ lib.optional a.mouse { mouse = true; };
  };
in
{
  imports = [ ./common.nix ];

  # The `dots.session.exec` entries that are Hyprland-only (see that option's
  # description in nix/home/desktop/session/default.nix): `reload` shells out to
  # `hyprctl` directly, and the three screenshot actions run hyprshot, whose
  # window and active-output modes drive Hyprland's own IPC. Contributed here
  # rather than in the WM-agnostic session module so that module stays
  # evaluable with no tiling WM in scope at all. `hyprmon-apply` used to be
  # another entry here; it is gone along with hyprmon itself, not ported.
  # The monitor layout is applied by qml/monitors/Watcher.qml now.
  dots.session.exec = {
    reload = "${hyprctl} reload";

    # `-m active` turns `-m output` into a non-interactive grab of the
    # focused output. Bare `-m output` opens a slurp monitor picker, which is
    # wrong for a key that should just fire. This is a behaviour change from
    # the grim script it replaces, which composited every output into one
    # image; hyprshot has no such mode.
    screenshot-output = "${hyprshot} -m output -m active";

    # `-z` freezes the screen for the duration of the selection, so a menu or
    # a hover state survives being pointed at. That is the reason to prefer
    # hyprshot over grim + slurp for the two interactive modes.
    screenshot-region = "${hyprshot} -m region -z";
    screenshot-window = "${hyprshot} -m window -z";
  };

  # hyprshot runs the capture in a backgrounded subshell and returns from its
  # foreground watcher the moment slurp exits, so grim, wl-copy and
  # notify-send are still working when the process systemd tracks is already
  # gone. On the default KillMode=control-group systemd tears the cgroup down
  # with that process and the screenshot is lost while the unit still reports
  # success. KillMode=process signals only the (already dead) main PID and
  # lets the capture finish. tests/session-units.nix asserts this on every
  # `dots-screenshot-*` unit, because the failure is silent otherwise.
  #
  # Contributed here rather than from the session module's `mkUnit` because
  # only hyprshot needs it: home-manager types `systemd.user.services` as an
  # `attrsOf submodule` whose `Service` is a freeform `attrsOf`, so this
  # merges into the units nix/home/desktop/session/default.nix generates instead of
  # conflicting with them. Spelled out one leaf at a time rather than built
  # with `lib.genAttrs`: `systemd.user.services.hyprlock` below is a second
  # leaf under the same path, and a whole-attrset assignment here would be a
  # duplicate definition of that path inside this one attrset literal.
  systemd.user.services."dots-screenshot-output@".Service.KillMode = "process";
  systemd.user.services."dots-screenshot-region@".Service.KillMode = "process";
  systemd.user.services."dots-screenshot-window@".Service.KillMode = "process";

  systemd.user.services.hyprlock = {
    Unit = {
      Description = "Screen locker for Wayland";
      Documentation = [ "man:hyprlock(1)" ];
      # If hyprlock exits cleanly, unlock the session:
      OnSuccess = [ "unlock.target" ];
      # When lock.target is stopped, stops this too:
      PartOf = [ "lock.target" ];
      # Delay lock.target until this service is ready:
      Before = [ "lock.target" ];
    };
    Service = {
      # systemd will consider this service started when hyprlock forks...
      Type = "forking";
      # ... and hyprlock will fork only after it has locked the screen.
      ExecStart = "${lib.getExe pkgs.hyprlock}";
      # If hyprlock crashes, always restart it immediately:
      Restart = "on-failure";
      RestartSec = 0;
    };
    Install = {
      WantedBy = [ "lock.target" ];
    };
  };
  wayland.windowManager.hyprland = {
    systemd.enable = false;
    enable = true;
    package = null;
    configType = "lua";

    settings = {
      # local mod = "SUPER". renderSettings emits all _var locals before
      # the call entries, so this precedes every hl.bind(mod .. …) below.
      mod = {
        _var = "SUPER";
      };

      # No static `monitor` block: Hyprland 0.55+ retired the hyprlang
      # `keyword` IPC for the Lua ("non-legacy") parser, so a
      # `hyprctl keyword monitor …` call is a silent no-op (exit 0 with an
      # error string). The scale is therefore applied at runtime by the
      # shell's own monitor watcher
      # (nix/home/desktop/quickshell/qml/monitors/Watcher.qml) via
      # `hyprctl eval 'hl.monitor({...})'`, not from this config file.

      # No exec-once / hl.on("hyprland.start", ...) block. `awww-daemon` is a
      # systemd --user unit instead, WantedBy graphical-session.target
      # (nix/home/desktop/session/default.nix), so nothing needs to launch
      # it from the Lua DSL any more. `nm-applet` was the same kind of unit
      # until Network.qml grew its own access-point write path and it was
      # deleted outright. `hyprmon apply` and
      # `wallpaper-tui --restore` are gone rather than ported: `main` deleted
      # both hyprmon and wallpaper-tui outright, in favour of
      # qml/monitors/Watcher.qml and qml/wallpaper/{Picker,Rotation}.qml.
      # Quickshell's own unit is deliberately not one of this module's
      # generated ones either. See the comment on `execDefaults` in
      # nix/home/desktop/session/default.nix for why.

      # env = [ "X,24" … ] (hyprlang comma-strings) → one hl.env(name, val)
      # call per pair, via _args. The eight portable variables come from
      # `config.dots.session.sessionVariables` (nix/home/desktop/session/default.nix),
      # the same attrset `systemd.user.sessionVariables` reads, so the two
      # can never drift, merged with the two that stay WM-specific here,
      # since both are always "Hyprland". `lib.mapAttrsToList` walks names in
      # sorted order, so the rendered hyprland.lua now lists these
      # alphabetically rather than in the hand-written order above.
      env =
        lib.mapAttrsToList
          (name: value: {
            _args = [
              name
              value
            ];
          })
          (
            cfg.sessionVariables
            // {
              XDG_CURRENT_DESKTOP = "Hyprland";
              XDG_SESSION_DESKTOP = "Hyprland";
            }
          );

      # general/decoration/dwindle/master/misc/input/animations.enabled
      # all go into ONE hl.config({ … }) call. `col.*` (dotted in
      # hyprlang) becomes a nested `col` table. The Lua API reads
      # col.active_border / col.inactive_border, not ["col.active_border"].
      config = {
        # gaps_in/gaps_out/border_size/layout come from the settings panel's
        # Window manager page (nix/home/desktop/quickshell/qml/settings/Settings.qml)
        # now, persisted to settings.nix and applied live via `hyprctl
        # keyword`, see that page's applyLive()/wm.js for the live half.
        # nix/system/defaults.nix's wmGapsIn/wmGapsOut/wmBorderSize/wmLayout match
        # the literals this replaced exactly, so a rebuild with no settings
        # panel edit yet made is a no-op.
        general = {
          gaps_in = settings.wmGapsIn;
          gaps_out = settings.wmGapsOut;
          border_size = settings.wmBorderSize;
          col = {
            active_border = "rgba(9aa5ceff)";
            inactive_border = "rgba(16161dff)";
          };
          layout = settings.wmLayout;
          allow_tearing = false;
        };

        decoration = {
          rounding = 10;
          # 0.75 opacity on every window (active + inactive) so the background
          # blur below shows through. Every window becomes frosted glass.
          # Hyprland opacity is a PRODUCT, so this multiplies with any per-app
          # opacity (terminals etc.), nudging them slightly more transparent.
          # Chosen over a per-window `opacity 0.75 override, .*` rule because
          # active_opacity/inactive_opacity are typed Lua fields (guaranteed to
          # eval), whereas the override-style window-rule field isn't in the
          # shipped hl.meta.lua. Same visual result, no crash risk.
          active_opacity = 0.9;
          inactive_opacity = 0.75;
          # Heavy blur. size/passes are GLOBAL: Hyprland has no per-window or
          # per-layer strength, so these numbers are what gives the beamenu
          # launcher its frosted backdrop (see the layer_rule below), and every
          # window inherits the same depth. 3 passes at size 8 is the usual
          # ceiling before the cost stops being worth it; going higher mostly
          # buys smear, not depth.
          blur = {
            enabled = true;
            size = 8;
            passes = 3;
            new_optimizations = true;
            xray = false;
          };
          shadow = {
            enabled = true;
            range = 10;
            render_power = 3;
            color = "rgba(1a1a2ecc)";
          };
        };

        dwindle = {
          preserve_split = true;
        };
        master = {
          new_status = "master";
        };

        misc = {
          force_default_wallpaper = 0;
          disable_hyprland_logo = true;
        };

        input = {
          kb_layout = "us";
          kb_options = "caps:escape";
          # wmFollowMouse is a bool on the settings side (the panel only ever
          # offers on/off) where Hyprland's own follow_mouse is an int
          # (0/1/2/3); true maps to Hyprland's own default 1, false to 0.
          # See nix/system/defaults.nix's comment on the key and wm.js's matching
          # boolAsInt conversion for the live-apply half.
          follow_mouse = if settings.wmFollowMouse then 1 else 0;
          sensitivity = 0;
          touchpad = {
            natural_scroll = true;
            drag_lock = false;
          };
        };

        # animations.enabled lives in hl.config; the bezier curve and the
        # per-leaf animation calls are the top-level `curve`/`animation`
        # keys below (HM's importantPrefixes emits `curve` first).
        animations = {
          enabled = settings.wmAnimations;
        };
      };

      # Force blur on every window (the hyprlang `blur, .*` rule, in Lua form:
      # hl.window_rule({ name=…, match={ class=".*" }, blur=true })). The
      # global active_opacity/inactive_opacity in config.decoration above
      # already makes windows translucent so the background blur reads through;
      # this rule also forces blur on windows that would otherwise opt
      # out, so the effect is uniform across everything.
      window_rule = [
        {
          name = "force-blur";
          match = {
            class = ".*";
          };
        }
      ];

      # The launcher draws into a wlr-layer-shell surface, and its namespace is
      # the only handle a rule has on it, since a layer surface carries no
      # class and no title. It is set in the QML
      # (nix/home/desktop/quickshell/qml/launcher/Launcher.qml) rather than being
      # whatever the toolkit happened to hardcode.
      #
      # ignore_alpha 0.1 is what makes the blur actually show: Hyprland skips
      # blurring behind pixels below the threshold, and the panel background is
      # deliberately translucent. Leaving it at the default would blur only the
      # fully opaque text.
      #
      # Blur STRENGTH is global in Hyprland: there is no per-layer size or
      # pass count, so the heavy look comes from decoration.blur above, which
      # this rule opts the launcher into. Add `dim_around = true` here for a
      # spotlight effect that darkens the rest of the screen.
      #
      # Field names verified against Hyprland 0.56.2's HL.LayerRuleSpec stub
      # (share/hypr/stubs/hl.meta.lua).
      #
      # The launcher is a Quickshell layer surface now, and it names itself.
      # bemenu hardcoded its namespace to "menu", which is why the old rule
      # matched a word that said nothing about which program owned it; a
      # WlrLayershell sets its own, so the match reads as what it is.
      #
      # ignore_alpha stays: Hyprland skips blurring behind near-transparent
      # pixels, and the panel background is deliberately translucent, so
      # without it the blur is dropped exactly where it is wanted.
      layer_rule = [
        {
          name = "launcher-blur";
          match = {
            namespace = "dots-launcher";
          };
          blur = true;
          ignore_alpha = 0.1;
        }
      ];

      # myBezier, 0.05, 0.9, 0.1, 1.05 →
      # hl.curve("myBezier", { type = "bezier", points = {{0.05,0.9},{0.1,1.05}} }).
      curve = [
        {
          _args = [
            "myBezier"
            {
              type = "bezier";
              points = [
                [
                  0.05
                  0.9
                ]
                [
                  0.1
                  1.05
                ]
              ];
            }
          ];
        }
      ];

      animation = [
        {
          leaf = "windows";
          enabled = true;
          speed = 7;
          bezier = "myBezier";
        }
        {
          leaf = "windowsOut";
          enabled = true;
          speed = 7;
          bezier = "default";
          style = "popin 80%";
        }
        {
          leaf = "border";
          enabled = true;
          speed = 10;
          bezier = "default";
        }
        {
          leaf = "borderangle";
          enabled = true;
          speed = 8;
          bezier = "default";
        }
        {
          leaf = "fade";
          enabled = true;
          speed = 7;
          bezier = "default";
        }
        {
          leaf = "workspaces";
          enabled = true;
          speed = 6;
          bezier = "default";
        }
      ];

      # Touchpad gestures. Hyprland 0.55 replaces the old hyprlang `gestures`
      # section with the `hl.gesture({...})` API: built-in actions (workspace,
      # move, special) are strings; custom dispatchers are Lua functions.
      # 3-finger horizontal swipe switches workspaces, 4-finger horizontal moves
      # the active window, 4-finger down toggles the scratch special workspace.
      gesture = [
        {
          fingers = 3;
          direction = "horizontal";
          action = "workspace";
        }
        {
          fingers = 4;
          direction = "horizontal";
          action = "move";
        }
        {
          fingers = 4;
          direction = "down";
          action = lua ''function() hl.dsp.workspace.toggle_special("scratch") end'';
        }
      ];

      # Binds. hyprlang `bind`/`binde`/`bindm` collapse to one `hl.bind`
      # API: hl.bind(key, dispatcher, opts?). opts carries the flags that
      # were separate keywords: { repeating = true } for binde,
      # { mouse = true } for bindm. `lua` (mkLuaInline) wraps both the key
      # expression (mod .. " + Q") and the dispatcher (hl.dsp.*) so HM
      # emits them verbatim. Plain Nix strings ("Print", "XF86AudioMute")
      # pass through as quoted lua strings for binds with no modifier.
      #
      # Generated from `nix/home/desktop/session/actions.nix`, one `hl.bind` per row
      # that carries a `key`; table order is preserved so the rendered file
      # reads in the same sequence as before. `mkKey`/`mkDispatch`/`mkBind`
      # and `dispatchMap` above do the rendering. See the comment on
      # `dispatchMap` for the one part of this that is Hyprland-specific.
      # Comments explaining why a particular bind exists live in actions.nix
      # now, not here.
      bind = map mkBind keyedActions;
    };
  };

  # Screenshots run hyprshot from the `dots-screenshot-*@` units, through the
  # `dots-hyprshot` wrapper above, which resolves every binary as an absolute
  # store path and needs nothing from this list. hyprshot is listed anyway on
  # the same grounds nix/home/base/pkgs.nix uses elsewhere: it is useful by hand,
  # and a package a unit depends on ought to be visible in the profile. It
  # lives here rather than in pkgs.nix because it only speaks Hyprland's own
  # IPC, so it belongs with the rest of this module's Hyprland-only choices.
  # libnotify and xdg-user-dirs stay for interactive use: a shell calling
  # notify-send or xdg-user-dir by hand still wants them on PATH.
  #
  # xdg-desktop-portal-gtk is also listed here (not just in the system
  # xdg.portal.extraPortals) because NixOS sets NIX_XDG_DESKTOP_PORTAL_DIR to
  # the per-user profile portal dir, so xdg-desktop-portal only sees portal
  # backends that are in the user's environment.
  home.packages = [
    pkgs.hyprshot
    pkgs.libnotify
    pkgs.xdg-user-dirs
    pkgs.xdg-desktop-portal-gtk
  ];

  # package = null above means HM's auto-enabled xdg.portal can't add
  # configPackages for xdg-desktop-portal-hyprland, so it needs an explicit
  # portal config here. Scoped to Hyprland sessions (hyprland-portals.conf)
  # so GNOME sessions keep the system-wide gtk default from
  # nix/modules/desktop/desktop.nix; hyprland portal takes ScreenCast/Screenshot,
  # and gtk handles the rest (FileChooser, Settings, Inhibit, etc.).
  xdg.portal.config.hyprland = {
    default = [
      "hyprland"
      "gtk"
    ];
    "org.freedesktop.portal.Settings" = "gtk";
  };

  # hyprlock -f -c 000000 → hyprlock. Was a solid black background; now a
  # blurred, dimmed screenshot of the live desktop with a Tokyonight-themed
  # digital clock (matching waybar.nix's palette + Lilex Nerd Font) and a
  # password input field. PAM U2F unlock is wired up on the NixOS side in
  # nix/modules/desktop/desktop.nix (security.pam.services.hyprlock.u2fAuth).
  programs.hyprlock = {
    enable = true;
    settings = {
      general = {
        hide_cursor = true;
        disable_loading_bar = false;
        no_fade_in = false;
        no_fade_out = false;
      };

      # Background: screenshot of the desktop at launch, GPU-blurred and
      # dimmed so the clock/input read clearly over it. brightness < 1
      # darkens the framebuffer; a touch of noise avoids banding in the
      # blur. color is only used when path is empty/missing, so it's kept
      # as a fallback fill (pure Tokyonight bg) for the no-screenshot case.
      background = [
        {
          monitor = "";
          path = "screenshot";
          color = "rgba(1a1b26ff)";
          blur_passes = 3;
          blur_size = 4;
          new_optimizations = true;
          brightness = 0.5;
          contrast = 1.0;
          noise = 0.02;
        }
      ];

      # Subtle fade so the lock doesn't slap in. bezier must be defined
      # before the animation that references it (hyprlang parses top-down).
      animations = {
        enabled = true;
        bezier = "linear, 1, 1, 0, 0";
        animation = [
          "fadeIn, 1, 5, linear"
          "fadeOut, 1, 5, linear"
        ];
      };

      # Digital clock. $TIME is a hyprlock built-in that ticks every
      # second on its own, so no cmd polling needed. Centered column over
      # the input field: TIME (130px above center) → DATE (40px above) →
      # input (110px below). In hyprlock, +Y is up.
      label = [
        {
          monitor = "";
          text = "$TIME";
          color = "rgb(c0caf5)";
          font_size = 96;
          font_family = "Lilex Nerd Font";
          position = "0, 130";
          halign = "center";
          valign = "center";
          shadow_passes = 2;
          shadow_size = 3;
          shadow_color = "rgba(000000aa)";
          shadow_boost = 1.0;
        }
        {
          monitor = "";
          text = "cmd[update:60000] date +\"%A, %d %B %Y\"";
          color = "rgb(737aa2)";
          font_size = 28;
          font_family = "Lilex Nerd Font";
          position = "0, 40";
          halign = "center";
          valign = "center";
          shadow_passes = 1;
          shadow_size = 2;
          shadow_color = "rgba(000000aa)";
        }
      ];

      # Password input. Translucent Tokyonight-bg fill, accent-blue ring
      # that turns yellow while authenticating (check_color) and red on
      # failure (fail_color), with orange when caps lock is on. dots_center
      # centers the per-keystroke dots; rounding echoes hyprland's
      # decoration.rounding.
      input-field = [
        {
          monitor = "";
          size = "25%, 4%";
          outline_thickness = 2;
          dots_size = 0.33;
          dots_spacing = 0.3;
          dots_center = true;
          outer_color = "rgba(7aa2f7cc)";
          inner_color = "rgba(1a1b26cc)";
          font_color = "rgb(c0caf5)";
          font_family = "Lilex Nerd Font";
          fade_on_empty = false;
          placeholder_text = "Enter password";
          hide_input = false;
          rounding = 12;
          check_color = "rgba(e0af68ee)";
          fail_color = "rgba(f7768eee)";
          fail_text = "$PAMFAIL";
          fail_transition = 300;
          capslock_color = "rgba(ff9e64ee)";
          position = "0, -110";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };

  # redshift -l 48.15:17.11 -t 4500:3000 -b 0.9:0.75 → gammastep (redshift
  # itself is unmaintained; gammastep is its actively developed fork).
  services.gammastep = {
    enable = true;
    latitude = "48.15";
    longitude = "17.11";
    temperature = {
      day = 4500;
      night = 3000;
    };
    tray = true;
    settings.general = {
      brightness-day = 0.9;
      brightness-night = 0.75;
    };
  };
}
