# Waybar VPN + Proton Mail Bridge indicators

Date: 2026-07-21
Scope: `nix/home/waybar.nix` only (no new files).

## Goal

Two always-visible status pills on the waybar right cluster that reflect, at a
glance, whether the Proton VPN tunnel is up and whether the Proton Mail Bridge
daemon is running.

## Detection signals

### VPN — interface `proton0`

Proton VPN (nixpkgs `proton-vpn`, the GTK app) drives NetworkManager. The
installed `proton-vpn-api-core` source sets the tunnel interface name to a
fixed `proton0` for **both** backends:

- `…/protocol/wireguard/wireguard.py`: `VIRTUAL_DEVICE_NAME = "proton0"`
- `…/protocol/openvpn/openvpn.py`:   `VIRTUAL_DEVICE_NAME = "proton0"`

It is set via `NM.SETTING_CONNECTION_INTERFACE_NAME`. The connection's NM *ID*
is the server name (not a stable prefix), but the *interface name* is fixed, so
`test -d /sys/class/net/proton0` is a clean, ProtonVPN-specific "connected"
signal. The active server name for the tooltip is read with
`nmcli -t -f NAME,DEVICE connection show --active` filtered to `DEVICE==proton0`.

The kill-switch connections use the `pvpn-` prefix (`pvpn-killswitch`,
`pvpn-killswitch-ipv6[-perm]`, `pvpnksintrf0/1`, `pvpnrouteintrf0/1`) — these are
**not** the tunnel and are intentionally ignored.

### Bridge — systemd user service

`services.protonmail-bridge.enable` (home-manager) creates
`protonmail-bridge.service`, a user unit with
`ExecStart=…/bin/protonmail-bridge --noninteractive` and `Restart=always`,
`WantedBy=graphical-session.target`. Liveness is therefore
`systemctl --user is-active --quiet protonmail-bridge.service`.

Because the service runs `--noninteractive`, launching `protonmail-bridge` on
click would spawn a second instance fighting over the same keyring/IPC. The
click action must **not** do that — it restarts the unit instead.

## Modules

Two `custom` modules, polled every 5 s, emitting JSON (`return-type = "json"`).
Their scripts are built with `pkgs.writeShellApplication` in a `let` block inside
`waybar.nix` (no new files; independently runnable for testing).

### `custom/vpn` — `dots-vpn-pill`

- Connected (`/sys/class/net/proton0` exists):
  `{"text":"󰖂 <server>","class":"connected","tooltip":"Proton VPN — <server>"}`
- Disconnected:
  `{"text":"󰖂 off","class":"disconnected","tooltip":"Proton VPN — not connected"}`
- `on-click = "protonvpn-app"` (launch the Proton VPN GUI to connect).

### `custom/protonmail-bridge` — `dots-bridge-pill`

- Running:
  `{"text":"󰇨 bridge","class":"connected","tooltip":"Proton Mail Bridge — running (IMAP :1143 / SMTP :1025)"}`
- Stopped:
  `{"text":"󰇨 down","class":"disconnected","tooltip":"Proton Mail Bridge — stopped"}`
- `on-click = "systemctl --user restart protonmail-bridge.service"` (safe
  recovery; the unit runs `--noninteractive`, so restart — never spawn a GUI).

Glyphs verified present in Lilex Nerd Font (cmap check):
`󰖂` = mdi-vpn (U+F0582), `󰇨` = mdi-email (U+F01E8).

## Placement

Insert into `modules-right` as a connectivity cluster after `network`:

```
disk#home disk#nix backlight pulseaudio network custom/vpn custom/protonmail-bridge battery clock tray
```

## Styling (Tokyo Night, matches existing pills)

Add `#custom-vpn` and `#custom-protonmail-bridge` to the shared pill-base
selector (rounded capsule, `padding: 0 14px`, `margin: 4px 3px`).

State colors:

| Module        | Connected                          | Disconnected                              |
|---------------|------------------------------------|-------------------------------------------|
| VPN `󰖂`      | `#1a1b26` text on `#9ece6a` (green) | `#737aa2` text on `#1f2335` (dim/muted) — off is normal, not alarming |
| Bridge `󰇨`  | `#1a1b26` text on `#7dcfff` (cyan)  | `#1a1b26` text on `#f7768e` (red) — mail sync down = attention |

The JSON `class` field drives `.connected` / `.disconnected` on each module's
node, so the same selectors work as `#custom-vpn.connected` etc.

## Verification

- `just nix-lint` (flake eval + fmt + clippy + test) must pass.
- Each script runs standalone and prints valid JSON for both states.
- The bridge pill's "connected" branch is exercised live by the already-running
  `protonmail-bridge.service`; the VPN "connected" branch cannot be exercised
  here (no tunnel up) but the detection path is a single `test -d`.

## Out of scope

- No declarative WireGuard / secrets (intentionally absent — see
  `nix/home/proton/proton.nix` header; the GUI app owns the tunnel).
- No tray-icon replacement for the Proton VPN appindicator.
- No click-to-connect for VPN beyond launching the GUI.