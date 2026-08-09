{ pkgs, ... }:
let
  # Proton VPN status pill. The GTK app (nixpkgs `proton-vpn`) drives
  # NetworkManager and hard-codes its tunnel interface to `proton0` (set as
  # NM.SETTING_CONNECTION_INTERFACE_NAME in proton-vpn-api-core, for both the
  # WireGuard and OpenVPN backends). The connection's NM *id* is the server
  # name (no stable prefix), but the *interface* name is fixed — so its
  # presence == connected. The active NM connection on device `proton0` gives
  # the server name for the tooltip. The `pvpn-*` kill-switch connections are
  # intentionally ignored.
  vpnPill = pkgs.writeShellApplication {
    name = "dots-vpn-pill";
    text = ''
      set -euo pipefail
      if [[ -d /sys/class/net/proton0 ]]; then
        server=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
          | awk -F: '$2 == "proton0" { print $1; exit }')
        server=''${server:-ProtonVPN}
        printf '{"text":"󰖂 %s","class":"connected","tooltip":"Proton VPN — %s"}\n' "$server" "$server"
      else
        printf '{"text":"󰖂 off","class":"disconnected","tooltip":"Proton VPN — not connected"}\n'
      fi
    '';
  };

  # Proton Mail Bridge status pill. Bridge runs as a systemd user service
  # (services.protonmail-bridge) with `--noninteractive`, so liveness is
  # `systemctl --user is-active`. Its IMAP/SMTP proxy listens on 127.0.0.1
  # :1143 / :1025 (STARTTLS).
  bridgePill = pkgs.writeShellApplication {
    name = "dots-bridge-pill";
    text = ''
      set -euo pipefail
      if systemctl --user is-active --quiet protonmail-bridge.service; then
        printf '{"text":"󰘘 bridge","class":"connected","tooltip":"Proton Mail Bridge — running (IMAP :1143 / SMTP :1025)"}\n'
      else
        printf '{"text":"󰇨 down","class":"disconnected","tooltip":"Proton Mail Bridge — stopped"}\n'
      fi
    '';
  };

  # Network status pill. waybar's built-in network module auto-selects the
  # interface with the default route, which on this machine is the Proton VPN
  # killswitch dummy interface (pvpnksintrf0) — exposing its IP in the bar.
  # This pill queries NetworkManager directly, ignores VPN/tunnel/killswitch
  # connections, and shows the Wi-Fi ESSID (or the wired profile name) instead.
  networkPill = pkgs.writeShellApplication {
    name = "dots-network-pill";
    text = ''
      set -euo pipefail
      active=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null \
        | awk -F: '
            $3 == "802-11-wireless" { print "wifi:"$1":"$2; exit }
            $3 == "802-3-ethernet" && !eth { eth="eth:"$1":"$2 }
            END { if (eth) print eth }
          ')
      if [[ -z "$active" ]]; then
        printf '{"text":"󱚼 disconnected","class":"disconnected","tooltip":"No active network connection"}\n'
        exit 0
      fi
      kind=''${active%%:*}
      rest=''${active#*:}
      name=''${rest%%:*}
      device=''${rest#*:}
      case "$kind" in
        wifi)
          printf '{"text":"󰖩 %s","class":"wifi","tooltip":"Wi-Fi: %s on %s"}\n' "$name" "$name" "$device"
          ;;
        eth)
          printf '{"text":"󰈀 %s","class":"ethernet","tooltip":"Wired: %s on %s"}\n' "$name" "$name" "$device"
          ;;
      esac
    '';
  };
in
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
        "custom/network"
        "custom/vpn"
        "custom/protonmail-bridge"
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

      "disk#home" = {
        path = "/home";
        interval = 30;
        format = "󰋊 {percentage_used}%";
        tooltip-format = "{used} / {total} on '{path}' ({percentage_used}%)";
      };

      "disk#nix" = {
        path = "/nix/store";
        interval = 30;
        format = "󰆚 {percentage_used}%";
        tooltip-format = "{used} / {total} on '{path}' ({percentage_used}%)";
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

      # Network: NM-driven pill that shows the Wi-Fi ESSID (or wired profile name)
      # and never leaks interface IPs. VPN/tunnel/killswitch connections are ignored.
      "custom/network" = {
        exec = "${networkPill}/bin/dots-network-pill";
        interval = 5;
        return-type = "json";
      };

      # Proton VPN: tunnel interface `proton0` == connected (see vpnPill).
      # Click launches the GTK app to connect.
      "custom/vpn" = {
        exec = "${vpnPill}/bin/dots-vpn-pill";
        interval = 5;
        return-type = "json";
        on-click = "protonvpn-app";
      };

      # Proton Mail Bridge: systemd user service liveness (see bridgePill).
      # The unit runs `--noninteractive`, so restart (never spawn a GUI) on
      # click — recovers a wedged/stopped bridge.
      "custom/protonmail-bridge" = {
        exec = "${bridgePill}/bin/dots-bridge-pill";
        interval = 5;
        return-type = "json";
        on-click = "systemctl --user restart protonmail-bridge.service";
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
      #custom-network,
      #custom-vpn,
      #custom-protonmail-bridge,
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

      #custom-network {
        color: #1a1b26;
        background-color: #7aa2f7;
      }

      #custom-network.disconnected {
        color: #737aa2;
        background-color: #1f2335;
      }

      /* VPN pill: green when tunneled, dim when off (off is normal, not alarming). */
      #custom-vpn.connected {
        color: #1a1b26;
        background-color: #9ece6a;
      }

      #custom-vpn.disconnected {
        color: #737aa2;
        background-color: #1f2335;
      }

      /* Bridge pill: cyan when the daemon is up, red when mail sync is down. */
      #custom-protonmail-bridge.connected {
        color: #1a1b26;
        background-color: #7dcfff;
      }

      #custom-protonmail-bridge.disconnected {
        color: #1a1b26;
        background-color: #f7768e;
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
