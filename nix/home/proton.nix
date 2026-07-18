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
{ pkgs, ... }:
{
  services.protonmail-bridge.enable = true;

  home.packages = [ pkgs.proton-vpn ];

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
