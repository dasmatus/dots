{ ... }:
{
  programs.waybar = {
    enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 24;
      spacing = 4;

      modules-left = [ "hyprland/workspaces" ];
      modules-center = [ "hyprland/window" ];
      modules-right = [
        "disk"
        "backlight"
        "pulseaudio"
        "network"
        "battery"
        "clock"
        "tray"
      ];

      "hyprland/workspaces" = {
        format = "{id}";
        on-click = "activate";
      };

      "hyprland/window" = {
        format = "{title}";
        max-length = 60;
      };

      disk = {
        path = "/";
        format = "󰋊 {percentage_used}%";
        interval = 30;
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
        format = " {:%H:%M}";
        format-alt = " {:%d.%m.%Y %H:%M:%S}";
        tooltip-format = "{:%d.%m.%Y %H:%M:%S}";
      };

      tray.spacing = 10;
    };

    style = ''
      * {
        font-family: "Lilex Nerd Font";
        font-weight: bold;
        font-size: 13px;
        min-height: 0;
      }

      window#waybar {
        background-color: #1a1b26;
        color: #c0caf5;
        border-radius: 7px;
      }

      #workspaces button {
        padding: 0 8px;
        color: #737aa2;
        background: transparent;
      }

      #workspaces button.active {
        color: #c0caf5;
        background-color: #1f2335;
        border-radius: 7px;
      }

      #workspaces button.urgent {
        color: #f7768e;
      }

      #window {
        color: #545c7e;
        padding: 0 10px;
      }

      #disk,
      #backlight,
      #pulseaudio,
      #network,
      #battery,
      #clock,
      #tray {
        padding: 0 10px;
        color: #c0caf5;
      }

      #clock {
        color: #545c7e;
      }

      #battery.warning {
        color: #f7768e;
      }

      #battery.critical {
        color: #f7768e;
        font-weight: bold;
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
