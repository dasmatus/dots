# Proton stack: Mail Bridge (local IMAP/SMTP proxy), Thunderbird wired to
# it, and the official Proton VPN GUI app.
#
# VPN: no declarative WireGuard here, even though Proton's dashboard offers
# a per-device .conf (nmcli import). This is a public repo, and the
# WireGuard PrivateKey/PresharedKey would either land in the world-readable
# Nix store (the wireguard module's inline string options) or need
# agenix/sops just to keep it out of git — more secrets machinery than
# anything else in this repo carries. The GUI app (nixpkgs `proton-vpn`,
# formerly `protonvpn-gui`) drives NetworkManager (already enabled,
# nix/modules/desktop.nix) for both the tunnel and its kill switch, and
# uses the GNOME AppIndicator extension (also already enabled there) for
# its tray icon.
#
# One-time imperative steps this module cannot do for you:
#   - Bridge has no unattended first login: run `protonmail-bridge --cli`
#     once as this user, `login`, enter the Proton credentials/2FA, `info`
#     to read the generated Bridge password, then `exit`. This needs a
#     running Secret Service keyring (gnome-keyring, brought in by GNOME)
#     to persist the session — without one, Bridge can't store anything.
#   - Thunderbird's first connection prompts for that Bridge-generated
#     password (not the Proton account password), and — since Bridge's
#     TLS cert is self-signed (it only ever serves 127.0.0.1) — a security
#     exception for both the IMAP and SMTP ports, confirmed separately on
#     first use of each.
#   - Proton VPN GUI needs its own interactive login on first launch.
{ pkgs, lib, ... }:
{
  services.protonmail-bridge.enable = true;

  home.packages = [ pkgs.proton-vpn ];

  # Start the VPN app with the session, minimised to the tray.
  #
  # `--start-minimized` is a real upstream flag (proton/vpn/app/gtk/app.py adds
  # it via add_main_option), but it only takes effect when the app has a tray
  # indicator: app.py gates on `self._start_app_minimized and
  # self.tray_indicator`, so with no StatusNotifierItem host it would open a
  # normal window instead. Under Hyprland that host is waybar's `tray` module
  # (nix/home/waybar.nix), which is why this waits for the graphical session
  # rather than starting alongside it — waybar is launched from
  # hyprland.start, not by systemd, so there is no unit to order against and
  # the SNI watcher appears a moment after the session does.
  #
  # Restart=on-failure rather than always: a clean exit means the user quit the
  # app deliberately, and respawning it then would be a nuisance.
  systemd.user.services.protonvpn-app = {
    Unit = {
      Description = "Proton VPN, started minimised to the tray";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      # No tray host outside a Wayland/X session, so do not spawn a window.
      ConditionEnvironment = [ "WAYLAND_DISPLAY" ];
    };
    Service = {
      # The tray host has to be up before the app registers its item, and the
      # only signal available is time. A few seconds is enough for waybar and
      # cheap on a session that lasts hours.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${lib.getExe pkgs.proton-vpn} --start-minimized";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # `net` plugin identity lives in beamenu.nix, which waybar.nix also
  # contributes to; these are the VPN and mail-bridge commands.
  programs.beamenu.plugins.net.commands = [
    {
      id = "vpn-status";
      title = "VPN Status";
      description = "Every active connection, VPN included";
      mode = "view";
      exec = [
        "nmcli"
        "connection"
        "show"
        "--active"
      ];
    }
    {
      id = "bridge-restart";
      title = "Restart Mail Bridge";
      description = "Bounce the ProtonMail bridge user service";
      mode = "exec";
      exec = [
        "systemctl"
        "--user"
        "restart"
        "protonmail-bridge.service"
      ];
    }
  ];

  programs.thunderbird = {
    enable = true;
    profiles.default.isDefault = true;
  };

  accounts.email.accounts.proton = {
    primary = true;
    address = "Shadiness9530@proton.me";
    userName = "Shadiness9530@proton.me";
    realName = "Matus Mastena";

    # Bridge's own default ports/mode: STARTTLS on 1143 (IMAP) / 1025
    # (SMTP), not its alternate implicit-TLS 993/465 pairing.
    imap = {
      host = "127.0.0.1";
      port = 1143;
      tls.useStartTls = true;
    };
    smtp = {
      host = "127.0.0.1";
      port = 1025;
      tls.useStartTls = true;
    };

    thunderbird.enable = true;
  };
}
