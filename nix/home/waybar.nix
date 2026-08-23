# The bar shows only what is worth reading pre-attentively: workspaces, the
# focused window, battery, the clock and the tray.
#
# Disk, backlight, volume, network, VPN and the Proton Mail Bridge used to live
# here too. They moved into beamenu, where they are searchable rather than
# merely visible — type "wifi" and the row answers with the SSID. The three
# custom pills that backed network/VPN/bridge became Rust probes in
# rust/beamenu-status/src/parse.rs, keeping their exact selection rules; the
# 5-second refresh they polled at is now `beamenu --status-daemon`.
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
        "battery"
        "clock"
        "tray"
      ];

      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          default = "";
          active = "";
          urgent = "󰵙";
          empty = "";
          persistent = "";
          visible = "●";
          special = "●";
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
