# Proton stack: Mail Bridge (the local IMAP/SMTP proxy) and the mail client
# that talks to it.
#
# NO VPN. Proton VPN used to be here as a nixpkgs package plus a tray-docked
# systemd user unit; both are gone. It is provisioned outside this repo on the
# hosts that want it — secureblue ships a `ujust` recipe for it — and two
# managers driving the same NetworkManager connections is a fight, not a
# feature. Declarative WireGuard was never an option either: this is a public
# repo, and the PrivateKey/PresharedKey would land in the world-readable Nix
# store.
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
  config,
  pkgs,
  lib,
  settings,
  betterbird,
  ...
}:
{
  services.protonmail-bridge.enable = true;

  # No Proton VPN here at all — not a package, not a flatpak, not a unit. The
  # VPN is provisioned outside this repo on the hosts that want it (secureblue
  # exposes it as a `ujust` recipe), and a second, home-manager-managed copy
  # would fight it over the same NetworkManager connections.
  #
  # Proton Mail Bridge is a different matter and stays. Bridge is a background
  # daemon that other applications connect to over 127.0.0.1:1143/1025 — it is
  # a local server, not an app — and it must reach the login keyring to
  # persist its session. Both of those are exactly what a flatpak sandbox
  # exists to prevent, and `services.protonmail-bridge` above is a systemd
  # user unit that has no flatpak equivalent regardless.

  # `net` plugin identity lives in beamenu.nix, which waybar.nix also
  # contributes to; these are the VPN and mail-bridge commands.

  # Betterbird is the ONE GUI app in this profile that stays a Nix package
  # while the rest became Flathub refs (nix/home/base/flatpaks.nix), and it is
  # a deliberate exception rather than an oversight.
  #
  # Flathub does ship eu.betterbird.Betterbird. Taking it would cost the
  # declarative profile: `programs.thunderbird.package` is typed `package`,
  # not `nullOr package`, so the "configure but install nothing" trick that
  # nix/home/apps/{librewolf,zed}.nix use is not expressible here — the module
  # is either on and installing, or off and rendering nothing. Off would take
  # nix/home/proton/proton-calendar.nix down with it, since that module's
  # entire output is `programs.thunderbird.profiles.default.settings`: the
  # calendar subscription, the .ics path, the refresh interval. That is a
  # working feature with its own test (tests/proton-calendar.nix), traded for
  # nothing but consistency.
  #
  # It is also the app where "use the distro's package" argues least: nixpkgs
  # has no betterbird at all, so this repo builds its own
  # (nix/packages/betterbird.nix). There is no nixpkgs-vs-Flathub duplication
  # to remove here — only a local build to throw away.
  #
  # Still Betterbird rather than Thunderbird, for the original reason: the
  # StatusNotifierItem tray icon is what keeps mail arriving with no window
  # open (see nix/home/base/gnome-extensions.nix for the extension that makes
  # that tray exist on GNOME).
  programs.thunderbird = {
    enable = true;
    package = betterbird;
    profiles.default.isDefault = true;
  };

  # Identity comes from settings, never a literal — this repo is public, and an
  # address written here is an address in the clone history for good. Both keys
  # default to EMPTY in nix/system/defaults.nix, so a bare checkout carries no
  # address at all; see that file's "eval-time identity" block for why these
  # are settings rather than agenix secrets (Thunderbird's prefs are generated
  # at evaluation, and agenix cannot produce an eval-time value).
  #
  # These used to be dots.gitEmail/dots.gitName, i.e. the *commit* identity
  # reused as the mail account. That conflation is gone: the git identity is
  # now an agenix secret resolved at runtime (nix/home/secrets/identity.nix)
  # and has no eval-time representation to borrow. Keying the mail account off
  # its own protonEmail/protonRealName is also simply more honest — a Proton
  # address and a commit address are not the same fact.
  # Defined only when an address is actually configured. `address` is typed
  # `strMatching ".*@.*"`, so the empty default is not merely a blank account —
  # it is a TYPE ERROR that stops the whole home configuration from evaluating.
  # Without this guard a bare checkout of a public repo cannot be built at all,
  # by anyone, which is the same class of breakage the settings.nix symlink
  # used to cause and that this conversion exists to remove.
  #
  # Thunderbird stays enabled either way: a profile with no declared account is
  # a working mail client waiting for one to be added in the UI, whereas
  # disabling it would mean an unconfigured address silently uninstalls the
  # mail client. Bridge likewise still runs — it is the thing you log into
  # first, before there is any address to declare here.
  accounts.email.accounts.proton = lib.mkIf (settings.protonEmail != "") {
    primary = true;
    address = settings.protonEmail;
    userName = settings.protonEmail;
    realName = settings.protonRealName;

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
