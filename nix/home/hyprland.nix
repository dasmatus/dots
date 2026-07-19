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
# Hyprland system-wide; configType is pinned to "hyprlang" because Home
# Manager 26.05 defaults new configs to the Lua DSL, and this port keeps the
# classic hyprland.conf format instead.
{ pkgs, ... }:
{
  wayland.windowManager.hyprland = {
    systemd.enable = false;
    enable = true;
    package = null;
    configType = "hyprlang";

    settings = {
      monitor = "eDP-1, 1920x1080, 0x0, 1";

      "exec-once" = [
        "waybar"
        "nm-applet --indicator"
        "${pkgs.waytrogen}/bin/waytrogen --restore"
      ];

      env = [
        "XCURSOR_SIZE,24"
        "XCURSOR_THEME,Adwaita"
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"
        "QT_QPA_PLATFORM,wayland"
        "QT_QPA_PLATFORMTHEME,gtk3"
        "MOZ_ENABLE_WAYLAND,1"
        "NIXOS_OZONE_WL,1"
        "GDK_BACKEND,wayland,x11"
      ];

      general = {
        gaps_in = 5;
        gaps_out = 15;
        border_size = 2;
        "col.active_border" = "rgba(9aa5ceff)";
        "col.inactive_border" = "rgba(16161dff)";
        layout = "dwindle";
        allow_tearing = false;
      };

      decoration = {
        rounding = 10;

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

      animations = {
        enabled = true;
        bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
        animation = [
          "windows, 1, 7, myBezier"
          "windowsOut, 1, 7, default, popin 80%"
          "border, 1, 10, default"
          "borderangle, 1, 8, default"
          "fade, 1, 7, default"
          "workspaces, 1, 6, default"
        ];
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
          natural_scroll = false;
          "tap-to-click" = true;
          drag_lock = false;
        };
      };

      "$mainMod" = "SUPER";

      bind = [
        "$mainMod, Return, exec, alacritty"
        "$mainMod, D, exec, rofi -show drun -show-icons -theme tokyonight"
        "$mainMod SHIFT, F, exec, ~/.config/rofi/rofi-files.sh"
        "$mainMod, O, exec, obsidian"
        "$mainMod SHIFT, S, exec, flameshot gui"

        "$mainMod, Q, killactive"
        "$mainMod SHIFT, Space, togglefloating"
        "$mainMod, F, fullscreen, 0"
        "$mainMod, P, pseudo"

        "$mainMod, minus, togglespecialworkspace, scratch"
        "$mainMod SHIFT, minus, movetoworkspace, special:scratch"

        "$mainMod, H, movefocus, l"
        "$mainMod, L, movefocus, r"
        "$mainMod, K, movefocus, u"
        "$mainMod, J, movefocus, d"
        "$mainMod, Left, movefocus, l"
        "$mainMod, Right, movefocus, r"
        "$mainMod, Up, movefocus, u"
        "$mainMod, Down, movefocus, d"

        "$mainMod SHIFT, H, movewindow, l"
        "$mainMod SHIFT, L, movewindow, r"
        "$mainMod SHIFT, K, movewindow, u"
        "$mainMod SHIFT, J, movewindow, d"
        "$mainMod SHIFT, Left, movewindow, l"
        "$mainMod SHIFT, Right, movewindow, r"
        "$mainMod SHIFT, Up, movewindow, u"
        "$mainMod SHIFT, Down, movewindow, d"

        "$mainMod, 1, workspace, 1"
        "$mainMod, 2, workspace, 2"
        "$mainMod, 3, workspace, 3"
        "$mainMod, 4, workspace, 4"
        "$mainMod, 5, workspace, 5"
        "$mainMod, 6, workspace, 6"
        "$mainMod, 7, workspace, 7"
        "$mainMod, 8, workspace, 8"
        "$mainMod, 9, workspace, 9"
        "$mainMod, 0, workspace, 10"

        "$mainMod SHIFT, 1, movetoworkspace, 1"
        "$mainMod SHIFT, 2, movetoworkspace, 2"
        "$mainMod SHIFT, 3, movetoworkspace, 3"
        "$mainMod SHIFT, 4, movetoworkspace, 4"
        "$mainMod SHIFT, 5, movetoworkspace, 5"
        "$mainMod SHIFT, 6, movetoworkspace, 6"
        "$mainMod SHIFT, 7, movetoworkspace, 7"
        "$mainMod SHIFT, 8, movetoworkspace, 8"
        "$mainMod SHIFT, 9, movetoworkspace, 9"
        "$mainMod SHIFT, 0, movetoworkspace, 10"

        "$mainMod, mouse_down, workspace, e+1"
        "$mainMod, mouse_up, workspace, e-1"

        "$mainMod, S, togglespecialworkspace, magic"
        "$mainMod SHIFT, S, movetoworkspace, special:magic"

        "$mainMod ALT, L, exec, hyprlock"

        "$mainMod SHIFT, C, exec, hyprctl reload"
        "$mainMod SHIFT, E, exit"

        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
      ];

      binde = [
        "$mainMod ALT, H, resizeactive, -40 0"
        "$mainMod ALT, L, resizeactive, 40 0"
        "$mainMod ALT, K, resizeactive, 0 -40"
        "$mainMod ALT, J, resizeactive, 0 40"

        ", XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
      ];

      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
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

  # swaylock -f -c 000000 → hyprlock, solid black background to match.
  # NOTE: hyprlock needs `security.pam.services.hyprlock = {};` on the NixOS
  # side (nix/modules/*) to actually be able to unlock the session — out of
  # scope here, left for the orchestrator.
  programs.hyprlock = {
    enable = true;
    settings = {
      background = [
        { color = "rgba(000000ff)"; }
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
