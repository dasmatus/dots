# Por of files/hypr/hyprland.conf (deleted — see git history) plus its
# Wayland session daemons. Deliberate deviations from the X11-era conf:
#   - wallpaper exec-once dropped: waytrogen (nix/home/waytrogen.nix) owns
#     it now — `waytrogen --restore` re-applies the saved wallpaper on login;
#     the old static `swaybg -i …stripes…` line was removed because it ran
#     after waytrogen and clobbered it
#   - gentoo-pipewire-launcher dropped (Gentoo-only, already dead on NixOS)
#   - swayidle/swaylock exec-once dropped in favour of services.hypridle and
#     programs.hyprlock below
#   - libinput-gestures-setup dropped (X11-only)
#   - redshift exec-once dropped in favour of services.gammastep below
#   - all four `exec = gsettings ...` theme lines dropped: gtk/dconf
#     (default.nix) own theming now
#   - light -A/-U → brightnessctl (light was removed from nixpkgs)
#   - KeePassXC/Obsidian/Flameshot launched as native binaries (nix/home/
#     pkgs.nix) since the flatpak migration; OBSIDIAN_USE_WAYLAND (flatpak-
#     only) became NIXOS_OZONE_WL, which the nixpkgs Electron wrappers
#     (obsidian, vesktop — signal-desktop's ignores it) key off for
#     native Wayland
#   - lock bind switched from swaylock to hyprlock; the resize bind still
#     shares the same $mainMod ALT, L chord as the original conf did
#
# wayland.windowManager.hyprland.package is set to null because
# programs.hyprland.enable (nix/modules/desktop.nix) already installs
# Hyprland system-wide. configType is "lua": Home Manager 26.05 defaults
# new configs to the Lua DSL and this module uses it. `settings` is a Nix
# attrset that HM walks into hl.<key>(...) calls (lib.nix renderSettings):
# `_args` makes a multi-arg call, `_var` declares a `local`, and the `lua`
# alias (lib.generators.mkLuaInline) injects raw lua for key expressions
# (mod .. " + Q") and hl.dsp.* dispatchers. hyprlang-only keys are gone —
# exec-once → on("hyprland.start",…), binde → {repeating=true},
# bindm → {mouse=true}, bezier/animation → curve/animation.
{ pkgs, lib, ... }:
let
  lua = lib.generators.mkLuaInline;
in
{
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

      monitor = {
        output = "eDP-1";
        mode = "1920x1080";
        position = "0x0";
        scale = 1;
      };

      # exec-once → hl.on("hyprland.start", function() … end). The Lua DSL
      # has no exec-once; hyprland.start fires once at compositor boot.
      # ${pkgs.waytrogen} interpolates the store path into the lua string.
      on = {
        _args = [
          "hyprland.start"
          (lua ''
            function()
              hl.exec_cmd("waybar")
              hl.exec_cmd("nm-applet --indicator")
              hl.exec_cmd("${pkgs.waytrogen}/bin/waytrogen --restore")
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
          active_opacity = 0.75;
          inactive_opacity = 0.75;
          blur = {
            enabled = true;
            size = 3;
            passes = 1;
            new_optimizations = true;
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
            (lua ''hl.dsp.exec_cmd("alacritty")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + D"'')
            (lua ''hl.dsp.exec_cmd("rofi -show drun -show-icons -theme tokyonight")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + F"'')
            (lua ''hl.dsp.exec_cmd("~/.config/rofi/rofi-files.sh")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + O"'')
            (lua ''hl.dsp.exec_cmd("obsidian")'')
          ];
        }
        # flameshot now lives on Print (below); SUPER+SHIFT+S is reserved
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
        {
          _args = [
            (lua ''mod .. " + SHIFT + C"'')
            (lua ''hl.dsp.exec_cmd("hyprctl reload")'')
          ];
        }
        {
          _args = [
            (lua ''mod .. " + SHIFT + E"'')
            (lua "hl.dsp.exit()")
          ];
        }

        # flameshot (no modifier) — migrated off SUPER+SHIFT+S to Print
        {
          _args = [
            "Print"
            (lua ''hl.dsp.exec_cmd("flameshot gui")'')
          ];
        }

        # audio mute toggles (plain bind — not locked, not repeating)
        {
          _args = [
            "XF86AudioMute"
            (lua ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")'')
          ];
        }
        {
          _args = [
            "XF86AudioMicMute"
            (lua ''hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")'')
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

        {
          _args = [
            "XF86AudioRaiseVolume"
            (lua ''hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86AudioLowerVolume"
            (lua ''hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86MonBrightnessUp"
            (lua ''hl.dsp.exec_cmd("brightnessctl set 5%+")'')
            { repeating = true; }
          ];
        }
        {
          _args = [
            "XF86MonBrightnessDown"
            (lua ''hl.dsp.exec_cmd("brightnessctl set 5%-")'')
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

  # package = null above means HM's auto-enabled xdg.portal can't add
  # configPackages for xdg-desktop-portal-hyprland, so it needs an explicit
  # portal config here. Scoped to Hyprland sessions (hyprland-portals.conf)
  # so GNOME sessions keep the system-wide gtk default from
  # nix/modules/desktop.nix; hyprland portal takes ScreenCast/Screenshot,
  # everything else (FileChooser, Settings) falls through to gtk.
  xdg.portal.config.hyprland.default = [
    "hyprland"
    "gtk"
  ];

  # swayidle → hypridle: same three timers as the original exec-once block
  # (300s lock, 600s dpms off, dpms on on resume), before-sleep locks too.
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "hyprlock";
        before_sleep_cmd = "hyprlock";
      };
      listener = [
        {
          timeout = 300;
          on-timeout = "hyprlock";
        }
        {
          timeout = 600;
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
      ];
    };
  };

  # swaylock -f -c 000000 → hyprlock. Was a solid black background; now a
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
