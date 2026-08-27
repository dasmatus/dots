{
  config,
  pkgs,
  lib,
  ...
}:
let
  lua = lib.generators.mkLuaInline;
in
{
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
      # local mod = "SUPER" — renderSettings emits all _var locals before
      # the call entries, so this precedes every hl.bind(mod .. …) below.
      mod = {
        _var = "SUPER";
      };

      # No static `monitor` block: Hyprland 0.55+ retired the hyprlang
      # `keyword` IPC for the Lua ("non-legacy") parser, so the
      # `hyprctl keyword monitor …` calls hyprmon shells out to are now a
      # silent no-op (exit 0 with an error string). The scale is therefore
      # applied at runtime by the hyprmon daemon (nix/home/hyprmon.nix) via
      # `hyprctl eval 'hl.monitor({...})'`, not from this config file.

      # exec-once → hl.on("hyprland.start", function() … end). The Lua DSL
      # has no exec-once; hyprland.start fires once at compositor boot. Called
      # by name (like nm-applet) since wallpaper-tui is in home.packages.
      # The shell is deliberately not here: this hook fires only at boot, so
      # a `qs` started from it would stay dead through every rebuild until
      # the next login. It runs as a systemd user unit instead, which comes
      # back on switch — see nix/home/quickshell/default.nix. The cheatsheet
      # moved into the shell along with it, which is why there is no daemon
      # to start and no first-login sentinel to keep.
      # NB comments here are Nix (#), not Lua (--)
      # — anything inside the `lua ''...''` inline is emitted verbatim into
      # hyprland.lua.
      on = {
        _args = [
          "hyprland.start"
          (lua ''
            function()
              -- awww-daemon must be up before wallpaper-tui --restore
              -- talks to it; awww img blocks briefly and retries, so the
              -- ordering here is belt and braces rather than a race fix.
              hl.exec_cmd("awww-daemon")
              hl.exec_cmd("hyprmon apply")
              -- The bar's network pill reports state; nm-applet's tray
              -- icon is what actually offers a menu to switch networks,
              -- so it stays until the shell grows that.
              hl.exec_cmd("nm-applet --indicator")
              hl.exec_cmd("wallpaper-tui --restore")
            end'')
        ];
      };

      # env = [ "X,24" … ] (hyprlang comma-strings) → one hl.env(name, val)
      # call per pair, via _args.
      env = [
        {
          _args = [
            "XCURSOR_SIZE"
            "24"
          ];
        }
        {
          _args = [
            "XCURSOR_THEME"
            "Adwaita"
          ];
        }
        {
          _args = [
            "XDG_CURRENT_DESKTOP"
            "Hyprland"
          ];
        }
        {
          _args = [
            "XDG_SESSION_TYPE"
            "wayland"
          ];
        }
        {
          _args = [
            "XDG_SESSION_DESKTOP"
            "Hyprland"
          ];
        }
        {
          _args = [
            "QT_QPA_PLATFORM"
            "wayland"
          ];
        }
        {
          _args = [
            "QT_QPA_PLATFORMTHEME"
            "gtk3"
          ];
        }
        {
          _args = [
            "MOZ_ENABLE_WAYLAND"
            "1"
          ];
        }
        {
          _args = [
            "NIXOS_OZONE_WL"
            "1"
          ];
        }
        {
          _args = [
            "GDK_BACKEND"
            "wayland,x11"
          ];
        }
      ];

      # general/decoration/dwindle/master/misc/input/animations.enabled
      # all go into ONE hl.config({ … }) call. `col.*` (dotted in
      # hyprlang) becomes a nested `col` table — the Lua API reads
      # col.active_border / col.inactive_border, not ["col.active_border"].
      config = {
        general = {
          gaps_in = 5;
          gaps_out = 15;
          border_size = 2;
          col = {
            active_border = "rgba(9aa5ceff)";
            inactive_border = "rgba(16161dff)";
          };
          layout = "dwindle";
          allow_tearing = false;
        };

        decoration = {
          rounding = 10;
          # 0.75 opacity on every window (active + inactive) so the background
          # blur below shows through — every window becomes frosted glass.
          # Hyprland opacity is a PRODUCT, so this multiplies with any per-app
          # opacity (terminals etc.), nudging them slightly more transparent.
          # Chosen over a per-window `opacity 0.75 override, .*` rule because
          # active_opacity/inactive_opacity are typed Lua fields (guaranteed to
          # eval), whereas the override-style window-rule field isn't in the
          # shipped hl.meta.lua — same visual result, no crash risk.
          active_opacity = 0.9;
          inactive_opacity = 0.75;
          # Heavy blur. size/passes are GLOBAL — Hyprland has no per-window or
          # per-layer strength — so these numbers are what gives the beamenu
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
          follow_mouse = 1;
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
          enabled = true;
        };
      };

      # Force blur on every window (the hyprlang `blur, .*` rule, in Lua form:
      # hl.window_rule({ name=…, match={ class=".*" }, blur=true })). The
      # global active_opacity/inactive_opacity in config.decoration above
      # already makes windows translucent so the background blur reads through;
      # this rule additionally forces blur on windows that would otherwise opt
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
      # (nix/home/quickshell/qml/launcher/Launcher.qml) rather than being
      # whatever the toolkit happened to hardcode.
      #
      # ignore_alpha 0.1 is what makes the blur actually show: Hyprland skips
      # blurring behind pixels below the threshold, and the panel background is
      # deliberately translucent. Leaving it at the default would blur only the
      # fully opaque text.
      #
      # Blur STRENGTH is global in Hyprland — there is no per-layer size or
      # pass count — so the heavy look comes from decoration.blur above, which
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
      # were separate keywords — { repeating = true } for binde,
      # { mouse = true } for bindm. `lua` (mkLuaInline) wraps both the key
      # expression (mod .. " + Q") and the dispatcher (hl.dsp.*) so HM
      # emits them verbatim. Plain Nix strings ("Print", "XF86AudioMute")
      # pass through as quoted lua strings for binds with no modifier.
      bind = [
        # launchers
        {
          _args = [
            (lua ''mod .. " + Return"'')
            (lua ''hl.dsp.exec_cmd("kitty")'')
          ];
        }
        # The launcher is a Quickshell surface the shell already has open, so
        # this toggles it rather than spawning anything. beamenu ran a fresh
        # binary per keypress and got away with it because layer-shell plus
        # cairo starts fast; not starting at all is faster still.
        #
        # The IPC function is `toggle` and not `show` for a reason worth
        # knowing: `qs ipc call launcher show` is swallowed by the `qs ipc show`
        # subcommand, which prints the handler listing and exits successfully
        # without calling anything.
        #
        # One bind, not three. SUPER+D and SUPER+SHIFT+E both ran plain
        # `beamenu` (the second one's comment claimed a pre-seeded query, which
        # nothing ever seeded), and SUPER+comma skipped the launcher to open the
        # settings plugin's canvas view directly. Everything they reached is
        # inside the panel.
        {
          _args = [
            (lua ''mod .. " + Space"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call launcher toggle")'')
          ];
        }
        # Nautilus directly (GNOME Files, services.gnome.core-apps) — the
        # rofi-files.sh dmenu browser retired with the HyprTile conversion.
        {
          _args = [
            (lua ''mod .. " + SHIFT + F"'')
            (lua ''hl.dsp.exec_cmd("nautilus")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + O"'')
            (lua ''hl.dsp.exec_cmd("obsidian")'')
          ];
        }
        # Zed editor — the GUI code editor that replaces VSCodium. The nixpkgs
        # `zed-editor` package installs its binary as `zeditor` (its
        # meta.mainProgram), not `zed`, so the bare command name here is that
        # binary. programs.zed-editor (nix/home/zed.nix) puts it on PATH.
        {
          _args = [
            (lua ''mod .. " + Z"'')
            (lua ''hl.dsp.exec_cmd("zeditor")'')
          ];
        }
        # The keybind cheatsheet (nix/home/keybinds.nix). A plain toggle now:
        # the once-per-install sentinel and the --force flag that skipped it
        # went with eww.
        {
          _args = [
            (lua ''mod .. " + slash"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call cheatsheet toggle")'')
          ];
        }
        # The settings form (rust/settings-global, rendered by the shell). This
        # bind was retired when the settings menu became a beamenu plugin
        # answering the `set ` keyword, on the grounds that one door into the
        # launcher beat three. That keyword went with beamenu, and a form the
        # shell draws itself has no launcher row to hide behind, so the direct
        # bind comes back.
        {
          _args = [
            (lua ''mod .. " + comma"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call settings toggle")'')
          ];
        }
        #
        # Print (below) is the screenshot key; SUPER+SHIFT+S stays reserved
        # for the magic special workspace (was double-bound in hyprlang).

        # window ops
        {
          _args = [
            (lua ''mod .. " + Q"'')
            (lua "hl.dsp.window.close()")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + Space"'')
            (lua ''hl.dsp.window.float({ action = "toggle" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + F"'')
            (lua "hl.dsp.window.fullscreen()")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + P"'')
            (lua "hl.dsp.window.pseudo()")
          ];
        }

        # scratch special workspace
        {
          _args = [
            (lua ''mod .. " + minus"'')
            (lua ''hl.dsp.workspace.toggle_special("scratch")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + minus"'')
            (lua ''hl.dsp.window.move({ workspace = "special:scratch" })'')
          ];
        }

        # focus directional (HJKL + arrows)
        {
          _args = [
            (lua ''mod .. " + H"'')
            (lua ''hl.dsp.focus({ direction = "l" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + L"'')
            (lua ''hl.dsp.focus({ direction = "r" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + K"'')
            (lua ''hl.dsp.focus({ direction = "u" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + J"'')
            (lua ''hl.dsp.focus({ direction = "d" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + Left"'')
            (lua ''hl.dsp.focus({ direction = "l" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + Right"'')
            (lua ''hl.dsp.focus({ direction = "r" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + Up"'')
            (lua ''hl.dsp.focus({ direction = "u" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + Down"'')
            (lua ''hl.dsp.focus({ direction = "d" })'')
          ];
        }

        # move window directional (SHIFT + HJKL/arrows)
        {
          _args = [
            (lua ''mod .. " + SHIFT + H"'')
            (lua ''hl.dsp.window.move({ direction = "l" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + L"'')
            (lua ''hl.dsp.window.move({ direction = "r" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + K"'')
            (lua ''hl.dsp.window.move({ direction = "u" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + J"'')
            (lua ''hl.dsp.window.move({ direction = "d" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + Left"'')
            (lua ''hl.dsp.window.move({ direction = "l" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + Right"'')
            (lua ''hl.dsp.window.move({ direction = "r" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + Up"'')
            (lua ''hl.dsp.window.move({ direction = "u" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + Down"'')
            (lua ''hl.dsp.window.move({ direction = "d" })'')
          ];
        }

        # workspace 1-10 (key 0 → workspace 10)
        {
          _args = [
            (lua ''mod .. " + 1"'')
            (lua "hl.dsp.focus({ workspace = 1 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 2"'')
            (lua "hl.dsp.focus({ workspace = 2 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 3"'')
            (lua "hl.dsp.focus({ workspace = 3 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 4"'')
            (lua "hl.dsp.focus({ workspace = 4 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 5"'')
            (lua "hl.dsp.focus({ workspace = 5 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 6"'')
            (lua "hl.dsp.focus({ workspace = 6 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 7"'')
            (lua "hl.dsp.focus({ workspace = 7 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 8"'')
            (lua "hl.dsp.focus({ workspace = 8 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 9"'')
            (lua "hl.dsp.focus({ workspace = 9 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + 0"'')
            (lua "hl.dsp.focus({ workspace = 10 })")
          ];
        }

        # move window to workspace 1-10
        {
          _args = [
            (lua ''mod .. " + SHIFT + 1"'')
            (lua "hl.dsp.window.move({ workspace = 1 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 2"'')
            (lua "hl.dsp.window.move({ workspace = 2 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 3"'')
            (lua "hl.dsp.window.move({ workspace = 3 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 4"'')
            (lua "hl.dsp.window.move({ workspace = 4 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 5"'')
            (lua "hl.dsp.window.move({ workspace = 5 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 6"'')
            (lua "hl.dsp.window.move({ workspace = 6 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 7"'')
            (lua "hl.dsp.window.move({ workspace = 7 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 8"'')
            (lua "hl.dsp.window.move({ workspace = 8 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 9"'')
            (lua "hl.dsp.window.move({ workspace = 9 })")
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + 0"'')
            (lua "hl.dsp.window.move({ workspace = 10 })")
          ];
        }

        # mouse-wheel workspace cycling
        {
          _args = [
            (lua ''mod .. " + mouse_down"'')
            (lua ''hl.dsp.focus({ workspace = "e+1" })'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + mouse_up"'')
            (lua ''hl.dsp.focus({ workspace = "e-1" })'')
          ];
        }

        # magic special workspace
        {
          _args = [
            (lua ''mod .. " + S"'')
            (lua ''hl.dsp.workspace.toggle_special("magic")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + S"'')
            (lua ''hl.dsp.window.move({ workspace = "special:magic" })'')
          ];
        }

        # lock + session
        {
          _args = [
            (lua ''mod .. " + ALT + L"'')
            (lua ''hl.dsp.exec_cmd("hyprlock")'')
          ];
        }
        # The power menu had its own SUPER+SHIFT+E bind running plain `beamenu`,
        # the identical command SUPER+D ran, on the claim that the query was
        # pre-seeded to the session commands. Nothing seeded it. Those commands
        # live under the System pill, one Tab from opening SUPER+Space.
        {
          _args = [
            (lua ''mod .. " + SHIFT + C"'')
            (lua ''hl.dsp.exec_cmd("hyprctl reload")'')
          ];
        }

        # Print (no modifier) grabs the focused output with hyprshot, which
        # writes Screenshot_<stamp>.png into the xdg-user-dir PICTURES folder
        # itself; notify-send surfaces the folder. SUPER+Print is the region
        # variant. `&&` skips the notify if the capture failed. Both are also
        # reachable from beamenu's System provider.
        {
          _args = [
            "Print"
            (lua ''hl.dsp.exec_cmd("hyprshot -m output && notify-send \"Screenshot saved in $(xdg-user-dir PICTURES 2>/dev/null || echo ~/Pictures)\"")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + Print"'')
            (lua ''hl.dsp.exec_cmd("hyprshot -m region && notify-send \"Screenshot saved in $(xdg-user-dir PICTURES 2>/dev/null || echo ~/Pictures)\"")'')
          ];
        }

        # audio mute toggles (plain bind — not locked, not repeating)
        #
        # These call the shell's OSD rather than wpctl directly, so the change
        # is drawn as it is made. That is the whole point: a mute toggle that
        # shows nothing leaves you tapping the key to find out which way it
        # went. The shell sets the Pipewire node itself instead of spawning
        # wpctl, which dots-osd paid for twice per keypress.
        # See nix/home/quickshell/qml/osd/Osd.qml.
        {
          _args = [
            "XF86AudioMute"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd volumeMute")'')
          ];
        }
        {
          _args = [
            "XF86AudioMicMute"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd micToggle")'')
          ];
        }

        # Touchpad off and on, for typing on a laptop with the heel of a hand
        # in the way. Hyprland cannot be asked whether a device is enabled, so
        # the shell remembers it for the life of the process — which ends at
        # logout, exactly when Hyprland forgets the setting too.
        {
          _args = [
            (lua ''mod .. " + SHIFT + T"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call osd touchpadToggle")'')
          ];
        }

        # Privacy switch: mute the microphone, and name anything holding the
        # camera open so "privacy on" is never read as "the camera is off".
        {
          _args = [
            (lua ''mod .. " + SHIFT + P"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call osd privacyToggle")'')
          ];
        }

        # repeating binds (was `binde`): window resize + volume/brightness.
        # { repeating = true } as the third _args element replaces `binde`.
        # Not locked — the hyprlang source used `binde`, not `bindle`.
        {
          _args = [
            (lua ''mod .. " + ALT + H"'')
            (lua "hl.dsp.window.resize({ x = -40, y = 0, relative = true })")
            { repeating = true; }
          ];
        }
        {
          _args = [
            (lua ''mod .. " + ALT + L"'')
            (lua "hl.dsp.window.resize({ x = 40, y = 0, relative = true })")
            { repeating = true; }
          ];
        }
        {
          _args = [
            (lua ''mod .. " + ALT + K"'')
            (lua "hl.dsp.window.resize({ x = 0, y = -40, relative = true })")
            { repeating = true; }
          ];
        }
        {
          _args = [
            (lua ''mod .. " + ALT + J"'')
            (lua "hl.dsp.window.resize({ x = 0, y = 40, relative = true })")
            { repeating = true; }
          ];
        }

        # Volume and brightness, still ±5% and still repeating while held — but
        # through the shell, which moves the Pipewire node or runs
        # brightnessctl and then draws the resulting level as a progress bar.
        # The 1.5 boost ceiling on the way up lives there too
        # (nix/home/quickshell/qml/osd/Osd.qml); it is not lost here.
        {
          _args = [
            "XF86AudioRaiseVolume"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd volumeUp")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86AudioLowerVolume"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd volumeDown")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86MonBrightnessUp"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd brightnessUp")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86MonBrightnessDown"
            (lua ''hl.dsp.exec_cmd("qs ipc call osd brightnessDown")'')
            { repeating = true; }
          ];
        }

        # mouse binds (was `bindm`): { mouse = true } replaces the keyword.
        # movewindow → hl.dsp.window.drag(), resizewindow → hl.dsp.window.resize()
        # (mouse-drag form, no args).
        {
          _args = [
            (lua ''mod .. " + mouse:272"'')
            (lua "hl.dsp.window.drag()")
            { mouse = true; }
          ];
        }
        {
          _args = [
            (lua ''mod .. " + mouse:273"'')
            (lua "hl.dsp.window.resize()")
            { mouse = true; }
          ];
        }
      ];
    };
  };

  # Runtime tools for the Print-key screenshot: hyprshot does the Wayland
  # capture (on PATH via nix/home/beamenu.nix, which owns the screenshot and
  # recording tools now); libnotify's notify-send surfaces the saved
  # folder — the shell's notification server displays it, see
  # nix/home/quickshell/qml/notifications/Notifications.qml;
  # xdg-user-dirs provides xdg-user-dir, which both the bind and the shotter
  # use to resolve the PICTURES folder.
  #
  # xdg-desktop-portal-gtk is also listed here (not just in the system
  # xdg.portal.extraPortals) because NixOS sets NIX_XDG_DESKTOP_PORTAL_DIR to
  # the per-user profile portal dir, so xdg-desktop-portal only sees portal
  # backends that are in the user's environment.
  home.packages = [
    pkgs.libnotify
    pkgs.xdg-user-dirs
    pkgs.xdg-desktop-portal-gtk
  ];

  # package = null above means HM's auto-enabled xdg.portal can't add
  # configPackages for xdg-desktop-portal-hyprland, so it needs an explicit
  # portal config here. Scoped to Hyprland sessions (hyprland-portals.conf)
  # so GNOME sessions keep the system-wide gtk default from
  # nix/modules/desktop.nix; hyprland portal takes ScreenCast/Screenshot,
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
  # nix/modules/desktop.nix (security.pam.services.hyprlock.u2fAuth).
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

      # Digital clock — $TIME is a hyprlock built-in that ticks every
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
