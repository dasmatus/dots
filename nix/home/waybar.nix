{ ... }:
{
  programs.waybar = {
    enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 30;
      spacing = 4;

      modules-left = [ "hyprland/workspaces" ];
      modules-center = [ "hyprland/window" ];
      modules-right = [
        "disk#home"
        "disk#nix"
        "backlight"
        "pulseaudio"
        "network"
        "battery"
        "clock"
        "tray"
      ];

      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          default = "●";
          active = "●";
          urgent = "●";
          empty = "●";
          persistent = "●";
          visible = "●";
          special = "●";
        };
        persistent-workspaces = {
          "1" = [ ];
          "2" = [ ];
          "3" = [ ];
          "4" = [ ];
          "5" = [ ];
        };
      };

      "hyprland/window" = {
        icon = true;
        icon-size = 20;
        icon-spacing = 8;
        expand = true;
        format = "{title}";
        max-length = 60;
        separate-outputs = true;
        fallback = "";
        # Strip the trailing app-name suffix so the real app icon (icon = true,
        # resolved from gtk.iconTheme = MoreWaita) is the only icon shown — no
        # redundant nerd-font glyph next to it.
        rewrite = {
          "(.*) - Mozilla Firefox" = "$1";
          "(.*) — Mozilla Firefox" = "$1";
          "(.*) - Google Chrome" = "$1";
          "(.*) - Chromium" = "$1";
          "(.*) - Visual Studio Code" = "$1";
          "(.*) - Code - OSS" = "$1";
          "(.*) - Kitty" = "$1";
          "(.*) - Alacritty" = "$1";
          "(.*) - Discord" = "$1";
          "(.*) - Spotify" = "$1";
          "(.*) - YouTube" = "$1";
          "(.*) - zsh" = "$1";
          "(.*) - fish" = "$1";
        };
      };

      "disk#home" = {
        path = "/home";
        interval = 30;
        format = "󰋊 {percentage_used}%";
        tooltip-format = "{used} / {total} on {path} ({percentage_used}%)";
      };

      "disk#nix" = {
        path = "/nix/store";
        interval = 30;
        format = "󰆚 {percentage_used}%";
        tooltip-format = "{used} / {total} on {path} ({percentage_used}%)";
      };

      backlight = {
        format = "{icon} {percent}%";
        format-icons = [
          "󰃞"
          "󰃟"
          "󰃠"
        ];
      };

      pulseaudio = {
        format = "{icon} {volume}%";
        format-muted = "󰝟 muted";
        format-icons.default = [
          "󰕿"
          "󰖀"
          "󰕾"
        ];
        on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        scroll-step = 5;
      };

      network = {
        format-wifi = "󰖩 {essid}";
        format-ethernet = "󰈀 {ipaddr}";
        format-disconnected = "󱚼 disconnected";
        tooltip-format = "{ifname} via {gwaddr}";
      };

      battery = {
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-icons = [
          "󰂎"
          "󰁺"
          "󰁻"
          "󰁼"
          "󰁽"
          "󰁾"
          "󰁿"
          "󰂀"
          "󰂁"
          "󰂂"
          "󰁹"
        ];
        states = {
          warning = 30;
          critical = 15;
        };
      };

      clock = {
        interval = 1;
        format = " {:%H:%M}";
        format-alt = " {:%d.%m.%Y %H:%M:%S}";
        tooltip-format = "{:%d.%m.%Y %H:%M:%S}";
      };

      tray.spacing = 10;
    };

    style = ''
      * {
        font-family: "Lilex Nerd Font";
        font-weight: bold;
        font-size: 15px;
        min-height: 0;
      }

      /* Fully transparent bar surface so the pills float on the desktop. */
      window#waybar {
        background-color: transparent;
        color: #c0caf5;
      }

      /* Pill base: every module is a rounded capsule with dark text on accent. */
      #workspaces button,
      #window,
      #disk,
      #backlight,
      #pulseaudio,
      #network,
      #battery,
      #clock,
      #tray {
        border-radius: 9999px;
        padding: 0 14px;
        margin: 4px 3px;
        color: #1a1b26;
        background-color: #1f2335;
      }

      /* Workspaces render as bullet dots, state conveyed via color only. */
      #workspaces button {
        padding: 0 10px;
        color: #737aa2;
        background-color: transparent;
      }

      #workspaces button.active {
        color: #7aa2f7;
        background-color: transparent;
      }

      #workspaces button.urgent {
        color: #f7768e;
        background-color: transparent;
      }

      #workspaces button.empty {
        color: #3b4261;
      }

      #workspaces button.visible {
        color: #737aa2;
      }

      /* Centered window module: app icon + clearly visible title. */
      #window {
        background-color: transparent;
        color: #c0caf5;
        font-weight: 600;
        margin: 0 8px;
      }

      #window label {
        color: inherit;
        opacity: 1;
      }

      #window image {
        color: #c0caf5;
        opacity: 1;
        margin-right: 4px;
      }

      #window.empty {
        color: #737aa2;
      }

      /* Color-coded right-side pills: dark text on Tokyo Night accents. */
      #disk.home {
        color: #1a1b26;
        background-color: #9ece6a;
      }

      #disk.nix {
        color: #1a1b26;
        background-color: #bb9af7;
      }

      #backlight {
        color: #1a1b26;
        background-color: #7dcfff;
      }

      #pulseaudio {
        color: #1a1b26;
        background-color: #ff9e64;
      }

      #network {
        color: #1a1b26;
        background-color: #7aa2f7;
      }

      #battery {
        color: #1a1b26;
        background-color: #9ece6a;
      }

      #battery.warning {
        color: #1a1b26;
        background-color: #e0af68;
      }

      #battery.critical {
        color: #1a1b26;
        background-color: #f7768e;
        font-weight: bold;
      }

      #clock {
        color: #1a1b26;
        background-color: #bb9af7;
      }

      #tray {
        color: #c0caf5;
        background-color: #1f2335;
      }

      #tray > .passive {
        opacity: 0.6;
      }

      #tray > .needs-attention {
        color: #f7768e;
      }
    '';
  };
}
