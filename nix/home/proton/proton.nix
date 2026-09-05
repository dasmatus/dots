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
# nix/modules/desktop/desktop.nix) for both the tunnel and its kill switch, and
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
{
  pkgs,
  lib,
  dots,
  betterbird,
  ...
}:
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

      # Only the seven directives with no plausible conflict with this
      # unit's job. Held back on purpose: MemoryDenyWriteExecute (Python
      # GTK apps commonly JIT via their bindings/typelib loading),
      # RestrictAddressFamilies (this app monitors NetworkManager over
      # D-Bus/netlink — could plausibly cut into route/link monitoring,
      # untested here), ProtectHome/ProtectSystem (untested against
      # wherever proton-vpn keeps its own state/config). Rationale for the
      # seven that are safe matches mkUnit's baseline in
      # session/default.nix: none of clock/hostname/kernel-log/cgroup/
      # personality/realtime/setuid-setgid access is part of running a
      # tray-docked VPN GUI.
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # `net` plugin identity lives in beamenu.nix, which waybar.nix also
  # contributes to; these are the VPN and mail-bridge commands.

  programs.thunderbird = {
    enable = true;
    # Betterbird over Thunderbird for the StatusNotifierItem tray icon, which
    # is what keeps mail arriving with no window open. Same profile format
    # and same ~/.thunderbird path, so nothing downstream moves.
    package = betterbird;
    profiles.default.isDefault = true;
  };

  # Identity comes from the installer answers, never a literal. This repo is
  # public, and an address written here is an address in the clone history for
  # good. dots.gitEmail/dots.gitName are bridged from
  # /var/lib/dots/settings.nix by nix/modules/dots.nix, and nix/data/settings.nix is
  # a tracked SYMLINK to that file, so git stores the link and not the contents.
  # nix/home/shell/git.nix reads the same two values, which is what keeps the mail
  # account and the commit identity from drifting.
  #
  # This assumes the Proton address IS the git address, which holds here. Split
  # them by pointing this at the protonEmail key (nix/system/defaults.nix) instead.
  accounts.email.accounts.proton = {
    primary = true;
    address = dots.gitEmail;
    userName = dots.gitEmail;
    realName = dots.gitName;

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
